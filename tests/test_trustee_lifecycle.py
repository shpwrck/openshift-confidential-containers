"""Mock the proof runner's Trustee ownership and serving-version boundaries."""
import copy
import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from test_trustee_config import generated, t

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from proof_core import Incomplete, restart_trustee

spec = importlib.util.spec_from_file_location("trustee_runner_test", ROOT / "scripts/run-proofs.py")
runner_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner_module)


class ClusterFixture:
    context = "offline-test"

    def __init__(self):
        self.bom = json.loads((ROOT / "install/release-manifest.json").read_text())
        self.tc, self.kbs, self.maps = generated()
        self.tc.update(spec={"profileType": "Permissive"})
        self.tc["metadata"]["name"] = "trustee-config"
        self.kbs["metadata"]["uid"] = "kbs-uid"
        for name, cm in self.maps.items():
            cm["metadata"].update(uid=name + "-uid", resourceVersion="8")
        self.rotated, self.cycles, self.calls, self.reads = False, 0, [], []

    def template(self):
        # First post-restart observation is Ready but still mounts older ConfigMap data.
        version = "7" if self.rotated and self.cycles == 1 else "8"
        return {"metadata": {"name": "trustee-pod", "uid": "new" if self.rotated else "old", "labels": {"app": "kbs"},
                             "ownerReferences": [{"controller": True, "kind": "ReplicaSet", "uid": "rs-uid"}],
                             "annotations": {t.VERSIONS: ",".join(n + ":" + version for n in self.maps)}},
                "spec": {"containers": [], "volumes": []},
                "status": {"conditions": [{"type": "Ready", "status": "True"}]}}

    def get(self, kind, name="", namespace=""):
        self.reads.append((kind, name, namespace))
        if kind == "namespace":
            result = {"metadata": {"labels": {"coco.openshift.io/disposable": "true"}}}
        elif kind == "clusterversion":
            result = {"spec": {"clusterID": "test-id"}, "status": {
                "desired": {"version": self.bom["platform"]["version"], "image": self.bom["platform"]["releaseImage"]},
                "history": [{"version": self.bom["platform"]["version"], "image": self.bom["platform"]["releaseImage"], "state": "Completed"}],
                "conditions": [{"type": "Available", "status": "True"}, {"type": "Progressing", "status": "False"}, {"type": "Failing", "status": "False"}]}}
        elif kind == "csv":
            operator = next(op for op in self.bom["operators"].values() if op["startingCSV"] == name)
            result = {"metadata": {"name": name, "uid": name + "-uid"},
                      "status": {"phase": "Succeeded"}, "spec": {"version": operator["version"]}}
        elif kind == "runtimeclass":
            result = {"handler": "kata-snp"}
        elif kind == "trusteeconfigs":
            result = {"items": [self.tc]}
        elif kind == "trusteeconfig":
            result = self.tc
        elif kind == "kbsconfigs":
            result = {"items": [self.kbs]}
        elif kind == "configmap":
            result = self.maps[name]
        elif kind == "pods":
            result = {"items": [self.template()]}
        elif kind == "replicasets":
            result = {"items": [{"metadata": {"uid": "rs-uid", "ownerReferences": [
                {"controller": True, "kind": "Deployment", "uid": "dep-uid"}]}}]}
        elif kind == "deployment":
            if self.rotated:
                self.cycles += 1
            result = {"metadata": {"generation": 2, "uid": "dep-uid", "ownerReferences": [
                {"controller": True, "kind": "KbsConfig", "uid": "kbs-uid"}]}, "spec": {"replicas": 1, "template": self.template()},
                      "status": {"observedGeneration": 2, "updatedReplicas": 1, "availableReplicas": 1}}
        else:
            raise AssertionError("unexpected mock resource " + kind)
        return copy.deepcopy(result)

    def call(self, *args, data=None):
        self.calls.append((args, data))
        self.rotated = True


class TrusteeLifecycleTests(unittest.TestCase):
    def runner(self):
        instance = runner_module.Runner({"WORKER_CONTEXT": "offline", "TRUSTEE_CONTEXT": "offline",
                                        "COCO_DISPOSABLE_TEST": "1", "TRUSTEE_PROFILE": "Permissive", "TRUSTEE_LAB": "1"}, Path("/tmp"))
        instance.worker = instance.trustee = ClusterFixture()
        return instance

    def test_preflight_binds_owner_profile_and_exact_map_versions(self):
        instance = self.runner()
        # Isolate post-artifact-gate schema/lifecycle behavior. The real failing gate
        # is exercised below, and all release/CSV identities come from the actual BOM.
        with patch.object(runner_module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            evidence = instance.preflight()
        self.assertEqual(evidence["trusteeConfigUID"], "tc-uid")
        self.assertEqual(evidence["trusteeProfile"], "Permissive")
        self.assertEqual(evidence["kbsConfigUID"], "kbs-uid")
        self.assertEqual(evidence["operators"]["trustee"]["version"], instance.trustee.bom["operators"]["trustee"]["version"])
        self.assertEqual(evidence["configMaps"]["tc-cpu"]["resourceVersion"], "8")
        instance.trustee.maps["tc-cpu"]["metadata"]["annotations"] = {}
        with patch.object(runner_module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), self.assertRaisesRegex(Incomplete, "migration is not complete"):
            instance.preflight()
        self.assertEqual(instance.trustee.calls, [])

    def test_preflight_rejects_an_independent_kbsconfig(self):
        instance = self.runner()
        instance.trustee.kbs["metadata"]["ownerReferences"] = []
        with patch.object(runner_module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), self.assertRaisesRegex(Incomplete, "not owned"):
            instance.preflight()
        self.assertEqual(instance.trustee.calls, [])

    def test_actual_unresolved_bom_gate_performs_no_cluster_reads_or_writes(self):
        instance = self.runner()
        with tempfile.TemporaryDirectory(prefix="coco-proof-bom-") as directory:
            bom = copy.deepcopy(instance.trustee.bom)
            bom["catalog"]["resolution"] = "unresolved"
            manifest = Path(directory) / "release.json"
            manifest.write_text(json.dumps(bom))
            instance.env["RELEASE_MANIFEST"] = str(manifest)
            with self.assertRaisesRegex(Incomplete, "release identities are unresolved"):
                instance.preflight()
        self.assertEqual(instance.trustee.calls, [])
        self.assertEqual(instance.trustee.reads, [])

    def test_ready_new_pod_is_insufficient_until_config_versions_match(self):
        cluster = ClusterFixture()
        with patch("proof_core.time.sleep"):
            restart_trustee(cluster, "fixture-namespace", timeout=10)
        self.assertEqual(cluster.cycles, 2)
        self.assertEqual(len(cluster.calls), 1)
        args, data = cluster.calls[0]
        self.assertEqual(args, ("delete", "--raw=/api/v1/namespaces/fixture-namespace/pods/trustee-pod", "-f", "-"))
        self.assertEqual(data["preconditions"], {"uid": "old"})
        self.assertNotIn("gracePeriodSeconds", data)

    def test_rotation_refuses_unrelated_labelled_pod_before_any_delete(self):
        cluster = ClusterFixture()
        original = cluster.template
        def unrelated():
            pod = original()
            pod["metadata"]["ownerReferences"] = []
            return pod
        with patch.object(cluster, "template", side_effect=unrelated), self.assertRaisesRegex(Incomplete, "outside the selected deployment"):
            restart_trustee(cluster, "fixture-namespace", timeout=10)
        self.assertEqual(cluster.calls, [])

    def test_rotation_binds_explicit_trustee_name(self):
        cluster = ClusterFixture()
        with self.assertRaisesRegex(Incomplete, "rotation target differs"):
            restart_trustee(cluster, "fixture-namespace", timeout=10, trustee_name="another-trustee")
        self.assertEqual(cluster.calls, [])


if __name__ == "__main__":
    unittest.main()
