#!/usr/bin/env python3
"""Worker installer regression tests; no cluster or real oc calls."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("worker_install", ROOT / "scripts/lib/worker_install.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerInstallTests(unittest.TestCase):
    def setUp(self):
        self.bom = json.loads((ROOT / "install/release-manifest.json").read_text())
        # Explicit synthetic CSV identities for logic fixtures only, never deployment data.
        for op in self.bom["operators"].values():
            op["startingCSV"] = op["startingCSV"] or op["package"] + ".v0.0.0-fixture"

    def plan(self):
        csv = self.bom["operators"]["osc"]["startingCSV"]
        return {"spec":{"approval":"Manual", "clusterServiceVersionNames":[csv]}, "status":{"plan":[{"resource":{"kind":"ClusterServiceVersion", "name":csv, "catalogSource":self.bom["catalog"]["source"], "catalogSourceNamespace":"openshift-marketplace"}}]}}

    def check_plan(self, plan):
        worker.check_plan(plan, self.bom, "snp", False, self.bom["operators"]["osc"]["startingCSV"])

    def test_reviewed_plan_is_accepted(self):
        self.check_plan(self.plan())

    def test_unknown_dependency_is_never_approved(self):
        plan = self.plan(); plan["spec"]["clusterServiceVersionNames"].append("unreviewed.v99")
        with self.assertRaisesRegex(ValueError, "unreviewed"):
            self.check_plan(plan)

    def test_different_catalog_is_never_approved(self):
        plan = self.plan(); plan["status"]["plan"][0]["resource"]["catalogSource"] = "unexpected-catalog"
        with self.assertRaisesRegex(ValueError, "unexpected catalog"):
            self.check_plan(plan)

    def test_unresolved_plan_is_not_approved(self):
        plan = self.plan(); plan["status"]["plan"] = []
        with self.assertRaisesRegex(ValueError, "no resolved steps"):
            self.check_plan(plan)

    def test_worker_cluster_does_not_install_trustee_unless_lab(self):
        docs = []
        for file in ("namespaces.yaml", "operatorgroups.yaml", "subscriptions.yaml"):
            docs.extend(yaml.safe_load_all((ROOT / "gitops/base/operators" / file).read_text()))
        result = worker.transform(copy.deepcopy(docs), "operators", self.bom, "snp", False)
        self.assertFalse(any(d.get("metadata", {}).get("namespace") == "trustee-operator-system" for d in result))
        result = worker.transform(copy.deepcopy(docs), "operators", self.bom, "snp", True)
        self.assertTrue(any(d.get("kind") == "Subscription" and d["metadata"]["namespace"] == "trustee-operator-system" for d in result))

    def test_all_constraints_preserve_enforcement_mode(self):
        docs = list(yaml.safe_load_all((ROOT / "gitops/base/gatekeeper/constraint-coco-mem.yaml").read_text()))
        templates = worker.transform(copy.deepcopy(docs), "templates", self.bom, "snp", False)
        constraints = worker.transform(copy.deepcopy(docs), "constraints", self.bom, "snp", False)
        self.assertEqual(1, len(templates))
        self.assertEqual({"coco-container-memory-floor":"deny", "coco-container-memory-floor-unlabeled":"dryrun"}, {d["metadata"]["name"]:d["spec"]["enforcementAction"] for d in constraints})

    def test_customer_snp_does_not_expand_to_every_snp_node(self):
        docs = list(yaml.safe_load_all((ROOT / "gitops/base/kataconfig/kataconfig.yaml").read_text()))
        result = worker.transform(docs, "kata", self.bom, "snp", False, "customer")
        self.assertEqual({"amd.feature.node.kubernetes.io/snp":"true", "node-role.kubernetes.io/coco-snp":""}, result[0]["spec"]["kataConfigPoolSelector"]["matchLabels"])

    def kata_state(self):
        labels = {"amd.feature.node.kubernetes.io/snp":"true", "node-role.kubernetes.io/coco-snp":""}
        config = "rendered-kata-fixture"
        return {
            "kata":{"spec":{"enablePeerPods":False, "kataConfigPoolSelector":{"matchLabels":labels}}, "status":{
                "runtimeClasses":["kata-cc"], "conditions":[{"type":"InProgress", "status":"False", "reason":""}],
                "kataNodes":{"nodeCount":1,"readyNodeCount":1,"installed":["selected-node"]}}},
            "runtime":{"handler":"kata-snp"},
            "nodes":{"items":[{"metadata":{"name":"selected-node", "labels":labels, "annotations":{
                "machineconfiguration.openshift.io/state":"Done",
                "machineconfiguration.openshift.io/currentConfig":config,
                "machineconfiguration.openshift.io/desiredConfig":config}}, "status":{"conditions":[{"type":"Ready", "status":"True"}]}}]},
            "mcp":{"metadata":{"generation":2}, "spec":{"configuration":{"name":config}}, "status":{
                "observedGeneration":2, "configuration":{"name":config}, "machineCount":1,"readyMachineCount":1,"updatedMachineCount":1,"degradedMachineCount":0,
                "conditions":[{"type":"Updated", "status":"True"},{"type":"Updating", "status":"False"},{"type":"Degraded", "status":"False"}]}}
        }

    def test_completed_kata_installation_matches_actual_selected_node_config(self):
        worker.check_kata(self.kata_state(), self.bom, "snp", "customer")

    def test_existing_runtimeclass_cannot_hide_missing_kata_status(self):
        state = self.kata_state()
        del state["kata"]["status"]
        with self.assertRaisesRegex(ValueError, "reconciliation"):
            worker.check_kata(state, self.bom, "snp", "customer")

    def test_kata_waiting_for_mco_cannot_pass_on_old_runtime(self):
        state = self.kata_state()
        state["kata"]["status"]["waitingForMcoToStart"] = True
        with self.assertRaisesRegex(ValueError, "waiting for MCO"):
            worker.check_kata(state, self.bom, "snp", "customer")

    def test_previous_selected_node_set_cannot_satisfy_new_pool(self):
        state = self.kata_state()
        state["kata"]["status"]["kataNodes"]["installed"] = ["old-node"]
        with self.assertRaisesRegex(ValueError, "node set"):
            worker.check_kata(state, self.bom, "snp", "customer")

    def test_kata_mcp_must_observe_new_generation(self):
        state = self.kata_state()
        state["mcp"]["status"]["observedGeneration"] = 1
        with self.assertRaisesRegex(ValueError, "observed/completed"):
            worker.check_kata(state, self.bom, "snp", "customer")

    def test_stale_node_mco_state_cannot_pass_on_kata_status_alone(self):
        state = self.kata_state()
        state["nodes"]["items"][0]["metadata"]["annotations"]["machineconfiguration.openshift.io/currentConfig"] = "old-rendered-config"
        with self.assertRaisesRegex(ValueError, "not applied"):
            worker.check_kata(state, self.bom, "snp", "customer")

    def test_unresolved_release_stops_before_any_cluster_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp); log = path / "oc-calls"
            oc = path / "oc"
            oc.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$MOCK_OC_LOG"\nexit 99\n')
            oc.chmod(0o755)
            env = {"PATH":str(path)+":"+os.environ["PATH"], "WORKER_CONTEXT":"fixture-worker", "MOCK_OC_LOG":str(log)}
            result = subprocess.run(["bash", "scripts/apply-sno.sh"], cwd=ROOT, env=env, text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("unresolved", result.stderr)
            self.assertFalse(log.exists(), "unresolved artifact identities must stop before accessing any context")

    def test_worker_only_context_is_sufficient(self):
        result = subprocess.run(["bash", "-c", 'source scripts/lib/cluster-context.sh; WORKER_CONTEXT=fixture-worker; load_worker_context'], cwd=ROOT, env={"PATH":os.environ["PATH"]}, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
