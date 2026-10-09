#!/usr/bin/env python3
"""Mocked context, rollout and disposable-reset checks; never contacts a cluster."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOM = json.loads((ROOT / "install/release-manifest.json").read_text())
MOCK_OC = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["MOCK_OC_LOG"], "a") as log: log.write(json.dumps(args)+"\n")
if "--context=fixture-worker" not in args and "--context=fixture-trustee" not in args:
    raise SystemExit("missing explicit fixture context")
args = [a for a in args if not a.startswith(("--context=", "--request-timeout="))]
fixture = json.load(open(os.environ["MOCK_FIXTURE"]))
if args == ["whoami"]: print("fixture-user")
elif args[:1] == ["api-resources"]: print("\n".join(["namespaces", "pods"]+fixture.get("extraResources", [])))
elif args[:3] == ["get", "clusterversion", "version"]: print(json.dumps(fixture["cv"]))
elif args[:2] == ["get", "mcp"]:
    print(json.dumps({"items":[{"metadata":{"name":"fixture"}, "status":{"machineCount":1, "conditions":[{"type":"Updated", "status":"True"},{"type":"Updating", "status":"False"},{"type":"Degraded", "status":"False"}]}}]}))
elif args[:2] == ["get", "namespaces"]:
    if args[2] in fixture.get("namespaces", {}): print(json.dumps(fixture["namespaces"][args[2]]))
elif args[:2] == ["wait", "node"]: pass
elif args[:1] == ["-n"] and args[2:4] == ["get", "catalogsource"]: print("READY", end="")
elif args[:1] == ["-n"] and args[2:] == ["get", "pods", "-o", "json"]: print(json.dumps({"items":fixture.get("pods", [])}))
else:
    ns = ""
    if args[:1] == ["-n"]: ns, args = args[1], args[2:]
    if args[:1] == ["get"] and len(args) >= 3:
        obj = fixture.get("objects", {}).get(args[1]+"/"+args[2]+"@"+ns)
        if obj: print(json.dumps(obj))
    elif fixture.get("allowDelete") and args[:1] in (["delete"], ["patch"], ["wait"]): pass
    else: raise SystemExit("unexpected mocked oc call: " + repr(args))
'''


class WorkerSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "oc.log"
        self.fixture_file = self.root / "fixture.json"
        self.fixture = {"cv":{"status":{
            "desired":{"version":BOM["platform"]["version"], "image":BOM["platform"]["releaseImage"]},
            "history":[{"state":"Completed", "version":BOM["platform"]["version"], "image":BOM["platform"]["releaseImage"], "completionTime":"2026-10-05T00:00:00Z"}],
            "conditions":[{"type":"Available", "status":"True"}, {"type":"Progressing", "status":"False"}, {"type":"Failing", "status":"False"}]
        }}, "namespaces":{}}
        mock = self.root / "oc"
        mock.write_text(MOCK_OC)
        mock.chmod(0o755)
        # A failed stub guarantees report-only tests cannot access KDS.
        for name in ("curl", "snpguest"):
            stub = self.root / name
            stub.write_text("#!/bin/sh\nexit 7\n")
            stub.chmod(0o755)
        self.env = {"PATH":str(self.root)+":"+os.environ["PATH"], "MOCK_OC_LOG":str(self.log), "MOCK_FIXTURE":str(self.fixture_file), "VCEK_BUNDLE":str(self.root / "bundle")}

    def run_script(self, name, *args, env=None):
        self.fixture_file.write_text(json.dumps(self.fixture))
        return subprocess.run(["bash", "scripts/"+name, *args], cwd=ROOT, env={**self.env, **(env or {})}, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def baseline(self):
        return self.run_script("validate-sno-baseline.sh", env={"WORKER_CONTEXT":"fixture-worker"})

    def test_completed_healthy_selected_payload_passes(self):
        result = self.baseline()
        self.assertEqual(0, result.returncode, result.stdout+result.stderr)
        self.assertTrue(self.calls())

    def test_desired_payload_without_completed_history_fails(self):
        self.fixture["cv"]["status"]["history"][0]["state"] = "Partial"
        result = self.baseline()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("rollout is incomplete", result.stdout)

    def test_old_completed_entry_does_not_hide_latest_partial_entry(self):
        history = self.fixture["cv"]["status"]["history"]
        history.insert(0, {**history[0], "state":"Partial"})
        self.assertNotEqual(0, self.baseline().returncode)

    def test_missing_or_unhealthy_cvo_conditions_fail(self):
        original = copy.deepcopy(self.fixture["cv"]["status"]["conditions"])
        for kind in ("Available", "Progressing", "Failing"):
            with self.subTest(kind=kind):
                self.fixture["cv"]["status"]["conditions"] = [c for c in original if c["type"] != kind]
                self.assertNotEqual(0, self.baseline().returncode)
                self.fixture["cv"]["status"]["conditions"] = [{**c, "status":"False" if c["status"] == "True" else "True"} if c["type"] == kind else c for c in original]
                self.assertNotEqual(0, self.baseline().returncode)

    def test_collector_and_host_check_require_worker_context_before_oc(self):
        for script in ("collect-vcek.sh", "verify-snp-host.sh"):
            with self.subTest(script=script):
                result = self.run_script(script, "fixture-node")
                self.assertNotEqual(0, result.returncode)
                self.assertIn("WORKER_CONTEXT", result.stderr)
                self.assertEqual([], self.calls())

    def test_seed_requires_explicit_trustee_context(self):
        result = self.run_script("collect-vcek.sh", "--seed", env={"WORKER_CONTEXT":"fixture-worker"})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("TRUSTEE_CONTEXT", result.stderr)
        self.assertEqual([], self.calls())

    def test_report_collection_does_not_publish_or_use_ambient_context(self):
        report = self.root / "report.bin"
        report.write_bytes(b"x" * 1184)
        result = self.run_script("collect-vcek.sh", "--from-report", str(report))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("No Secrets were changed", result.stdout)
        self.assertEqual([], self.calls())

    def test_repository_cannot_be_used_for_certificate_state(self):
        result = self.run_script("collect-vcek.sh", "--download", env={"VCEK_BUNDLE":str(ROOT / "forbidden-fixture")})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("must be outside", result.stderr)
        self.assertFalse((ROOT / "forbidden-fixture").exists())

    def test_empty_download_bundle_reports_missing_input_without_array_error(self):
        result = self.run_script("collect-vcek.sh", "--download")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("no collected VCEK URLs", result.stderr)
        self.assertNotIn("unbound variable", result.stderr)
        self.assertEqual([], self.calls())

    def test_reset_requires_all_intent_and_context_flags_before_oc(self):
        valid = {"WORKER_CONTEXT":"fixture-worker", "TRUSTEE_CONTEXT":"fixture-worker", "TRUSTEE_LAB":"1", "ALLOW_DISPOSABLE_UNINSTALL":"1"}
        for field in valid:
            with self.subTest(missing=field):
                result = self.run_script("uninstall-coco.sh", env={k:v for k,v in valid.items() if k != field})
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.calls())

    def test_reset_with_unlabeled_namespace_stops_before_mutation(self):
        self.fixture["namespaces"] = {"trustee-operator-system":{"metadata":{"labels":{"coco.openshift.io/disposable":"true"}}}, "openshift-nfd":{"metadata":{"labels":{}}}}
        result = self.run_script("uninstall-coco.sh", env={"WORKER_CONTEXT":"fixture-worker", "TRUSTEE_CONTEXT":"fixture-worker", "TRUSTEE_LAB":"1", "ALLOW_DISPOSABLE_UNINSTALL":"1"})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("lacks coco.openshift.io/disposable", result.stderr)
        self.assertFalse(any(any(word in call for word in ("delete", "patch", "apply")) for call in self.calls()))

    def test_reset_validation_finds_dynamic_owned_proof_pods(self):
        self.fixture["namespaces"] = {"coco-validation":{"metadata":{"labels":{}}}}
        self.fixture["pods"] = [{"metadata":{"name":"coco-proof-dynamic-123", "labels":{"coco.openshift.io/proof-run":"test"}}}]
        result = self.run_script("uninstall-coco.sh", "validate-once", env={"WORKER_CONTEXT":"fixture-worker"})
        self.assertNotEqual(0, result.returncode)
        self.assertIn("coco-proof-dynamic-123", result.stdout)

    def test_reset_keeps_arguments_intact_for_namespaced_and_cluster_resources(self):
        self.fixture["allowDelete"] = True
        self.fixture["namespaces"] = {"coco-validation":{"metadata":{"labels":{"coco.openshift.io/disposable":"true"}}}}
        self.fixture["pods"] = [{"metadata":{"name":"coco-proof-fixture", "labels":{"coco.openshift.io/proof-run":"test"}}}]
        self.fixture["extraResources"] = ["runtimeclasses.node.k8s.io"]
        deleting = {"metadata":{"deletionTimestamp":"2026-10-05T00:00:00Z", "finalizers":["fixture-finalizer"]}}
        self.fixture["objects"] = {"pods/coco-proof-fixture@coco-validation":deleting, "runtimeclasses.node.k8s.io/kata-cc@":deleting}
        result = self.run_script("uninstall-coco.sh", env={"WORKER_CONTEXT":"fixture-worker", "TRUSTEE_CONTEXT":"fixture-worker", "TRUSTEE_LAB":"1", "ALLOW_DISPOSABLE_UNINSTALL":"1", "FORCE_FINALIZERS":"1"})
        self.assertEqual(0, result.returncode, result.stderr)
        calls = [[a for a in call if not a.startswith(("--context=", "--request-timeout="))] for call in self.calls()]
        self.assertIn(["-n", "coco-validation", "delete", "pods", "coco-proof-fixture", "--ignore-not-found", "--wait=false"], calls)
        self.assertIn(["delete", "runtimeclasses.node.k8s.io", "kata-cc", "--ignore-not-found", "--wait=false"], calls)
        patch = '{"metadata":{"finalizers":[]}}'
        self.assertIn(["-n", "coco-validation", "patch", "pods", "coco-proof-fixture", "--type=merge", "-p", patch], calls)
        self.assertIn(["patch", "runtimeclasses.node.k8s.io", "kata-cc", "--type=merge", "-p", patch], calls)
        self.assertFalse(any("" in call for call in calls), "empty optional namespace must add zero arguments")


if __name__ == "__main__":
    unittest.main()
