import copy
import contextlib
import io
import subprocess
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from proof_core import (Incomplete, ProofFailure, ResourceEdit, application_started,
                        bind_initdata_policy, denial_matches, resource_released, trustee_denial_matches)

spec = importlib.util.spec_from_file_location("run_proofs", ROOT / "scripts/run-proofs.py")
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


class FakeCluster:
    def __init__(self):
        self.object = {"apiVersion": "v1", "kind": "ConfigMap",
                       "metadata": {"name": "policy", "uid": "original", "resourceVersion": "1",
                                    "labels": {"retain": "yes"}, "annotations": {"migration": "retained"}},
                       "data": {"policy.rego": "approved", "other": "retain"}, "binaryData": {"blob": "AA=="}}

    def get(self, *args, **kwargs):
        return copy.deepcopy(self.object)

    def call(self, *args, data=None):
        assert args[0] == "patch"
        for operation in data:
            if operation["op"] == "test":
                value = self.object
                for part in operation["path"].split("/")[1:]:
                    value = value[part]
                if value != operation["value"]:
                    raise Incomplete("concurrent resource edit")
            else:
                self.object["data"] = copy.deepcopy(operation["value"])
        self.object["metadata"]["resourceVersion"] = str(int(self.object["metadata"]["resourceVersion"]) + 1)
        return ""


class ProofOracles(unittest.TestCase):
    def test_crashed_application_is_still_a_denial_failure(self):
        pod = {"status": {"phase": "Failed", "containerStatuses": [{"lastState": {"terminated": {"startedAt": "2026-10-05T00:00:00Z"}}}]}}
        self.assertTrue(application_started(pod))

    def test_init_success_is_resource_release_even_before_app(self):
        pod = {"status": {"phase": "Pending", "initContainerStatuses": [{"name": "attestation-gate", "state": {"terminated": {"exitCode": 0}}}]}}
        self.assertTrue(resource_released(pod))
        self.assertFalse(application_started(pod))

    def test_signature_oracle_rejects_unrelated_failures(self):
        for text in ("InvalidImageName: signature", "Fetching signature policy", "signature verification failed: no such host", "sigstore policy resource fetched"):
            with self.subTest(text=text):
                self.assertFalse(denial_matches("rung-signed", text))
        self.assertTrue(denial_matches("rung-signed", "signature verification failed: key mismatch"))
        self.assertTrue(denial_matches("rung-signed", "no matching signatures"))
        self.assertTrue(denial_matches("rung-signed", "Image policy rejected: Denied by policy: rejected by `sigstoreSigned` rule"))
        self.assertFalse(denial_matches("rung-signed", "Image policy rejected: default policy rejects image"))
        self.assertFalse(denial_matches("rung-signed", "Fetched sigstoreSigned rule"))

    def test_generic_vcek_or_measurement_text_is_not_denial(self):
        self.assertFalse(denial_matches("air-gap", "VCEK offline verifier initialized"))
        self.assertFalse(denial_matches("rung-rvps", "measurement received"))
        self.assertTrue(denial_matches("air-gap", "Certificate chain verification failed"))

    def test_server_denial_requires_specific_failure_and_same_peer_request(self):
        error = "ERROR kbs::error: verify TEE evidence failed\nCaused by: Certificate chain from KDS failed verification\n"
        access = 'INFO actix_web::middleware::logger: 10.128.0.68 "POST /kbs/v0/attest HTTP/1.1" 401 140\n'
        self.assertTrue(trustee_denial_matches("air-gap", error + access, "10.128.0.68"))
        self.assertFalse(trustee_denial_matches("air-gap", access, "10.128.0.68"))
        self.assertFalse(trustee_denial_matches("air-gap", error + access, "10.128.0.69"))
        self.assertFalse(trustee_denial_matches("air-gap", error + access.replace("401", "200"), "10.128.0.68"))
        self.assertFalse(trustee_denial_matches("air-gap", error + access.replace("/attest", "/auth"), "10.128.0.68"))
        self.assertFalse(trustee_denial_matches("air-gap", error + access, ""))
        self.assertFalse(trustee_denial_matches("air-gap", error + access.replace("0.68", "0.69") + access, "10.128.0.68"))

    def test_server_policy_denial_requires_resource_path(self):
        access = 'INFO actix_web::middleware::logger: 10.128.0.70 "GET /kbs/v0/resource/default/credential/test HTTP/1.1" 403 12\n'
        self.assertTrue(trustee_denial_matches("rung-rvps", "ERROR PolicyDeny\n" + access, "10.128.0.70"))
        self.assertFalse(trustee_denial_matches("air-gap", "ERROR PolicyDeny\n" + access, "10.128.0.70"))

    def test_binding_preserves_vendor_checks_and_fails_unknown_policy(self):
        original = '''package policy
import rego.v1
default configuration := 36
configuration := 2 if { input.snp.debug == false }
executables := 3 if { input.snp.measurement in query_reference_value("snp_launch_measurement") }
trust_claims := {
  "configuration": configuration,
  "executables": executables,
}
'''
        result = bind_initdata_policy(original, "a" * 64)
        self.assertIn('input.snp.measurement in query_reference_value("snp_launch_measurement")', result)
        self.assertIn("configuration := 2 if { input.snp.debug == false }", result)
        self.assertIn('"configuration": coco_bound_configuration,', result)
        self.assertIn("default coco_bound_configuration := 36", result)
        with self.assertRaises(Incomplete):
            bind_initdata_policy("default allow := true", "a" * 64)
        with self.assertRaises(Incomplete):
            bind_initdata_policy(result, "b" * 64)

    def test_roundtrip_preserves_other_data_metadata_and_binary(self):
        cluster = FakeCluster()
        original = copy.deepcopy(cluster.object)
        with tempfile.TemporaryDirectory() as directory:
            edit = ResourceEdit(cluster, "configmap", "policy", "test", Path(directory))
            edit.change({"policy.rego": "denial fixture", "other": "retain"})
            edit.restore()
            self.assertEqual(cluster.object["data"], original["data"])
            self.assertEqual(cluster.object["binaryData"], original["binaryData"])
            self.assertEqual(cluster.object["metadata"]["annotations"], original["metadata"]["annotations"])
            self.assertEqual(edit.backup.stat().st_mode & 0o777, 0o600)

    def test_restore_refuses_overwrite_of_concurrent_customer_change(self):
        cluster = FakeCluster()
        with tempfile.TemporaryDirectory() as directory:
            edit = ResourceEdit(cluster, "configmap", "policy", "test", Path(directory))
            edit.change({"policy.rego": "denial fixture"})
            cluster.object["data"] = {"policy.rego": "other operator change"}
            with self.assertRaises(ProofFailure):
                edit.restore()
            self.assertEqual(cluster.object["data"], {"policy.rego": "other operator change"})
            self.assertTrue(edit.backup.exists())

    def test_restore_refuses_recreated_object(self):
        cluster = FakeCluster()
        with tempfile.TemporaryDirectory() as directory:
            edit = ResourceEdit(cluster, "configmap", "policy", "test", Path(directory))
            edit.change({"policy.rego": "fixture"})
            cluster.object["metadata"]["uid"] = "new-object"
            with self.assertRaises(ProofFailure):
                edit.restore()

    def test_failed_positive_stops_before_negative(self):
        runner = suite.Runner({"WORKER_CONTEXT": "test", "TRUSTEE_CONTEXT": "test"}, Path("/tmp"))
        runner.positive = Mock(side_effect=Incomplete("positive unavailable"))
        runner.negative = Mock()
        with self.assertRaises(Incomplete):
            runner.run("rung-kbs")
        runner.negative.assert_not_called()

    def test_encryption_cannot_silently_pass_as_skipped(self):
        runner = suite.Runner({"WORKER_CONTEXT": "test", "TRUSTEE_CONTEXT": "test",
                              "RUNG_ENCRYPTED_IMAGE": "registry/example@sha256:" + "a" * 64}, Path("/tmp"))
        with self.assertRaisesRegex(Incomplete, "EXPERIMENTAL_ENCRYPTED_IMAGES"):
            runner.run("rung-encrypted")


class ProofRestorationOrder(unittest.TestCase):
    def fixture(self):
        events = []
        runner = suite.Runner({"WORKER_CONTEXT": "fixture-worker", "TRUSTEE_CONTEXT": "fixture-trustee", "TEE": "snp"}, Path("/tmp"))
        edit = Mock()
        edit.original_data = {"reference_value": json.dumps({"snp_launch_measurement": "synthetic-reference-fixture"})}
        edit.backup = Path("/tmp/synthetic-proof-recovery.json")
        edit.change.side_effect = lambda data: events.append("restrict-reference")
        edit.restore.side_effect = lambda: events.append("restore-reference")
        runner.config_edit = Mock(return_value=edit)
        runner.render = Mock(return_value={"metadata": {"name": "fixture-negative"}})
        runner.positive = Mock(side_effect=lambda case, phase: events.append("positive-" + phase))

        def denied(case, pod):
            runner.negative_name = pod["metadata"]["name"]
            events.append("attributable-denial")

        runner.negative = Mock(side_effect=denied)
        runner.delete_pod = Mock(side_effect=lambda name: events.append("delete-negative"))
        return runner, edit, events

    def test_denied_pod_is_removed_before_restore_restart_and_recovery(self):
        runner, edit, events = self.fixture()
        with patch.object(suite, "restart_trustee", side_effect=lambda *args: events.append("restart")):
            runner.run("rung-rvps")
        self.assertEqual(events, ["positive-control", "restrict-reference", "restart", "attributable-denial",
                                  "delete-negative", "restore-reference", "restart", "positive-recovery"])
        self.assertEqual(runner.evidence["negativeCleanup"], "PASS")
        self.assertEqual(runner.evidence["restoration"], "PASS")
        edit.restore.assert_called_once()

    def test_cleanup_failure_leaves_restrictive_state_and_never_runs_recovery(self):
        runner, edit, events = self.fixture()
        runner.delete_pod.side_effect = Incomplete("simulated deletion timeout")
        with patch.object(suite, "restart_trustee", side_effect=lambda *args: events.append("restart")), self.assertRaisesRegex(ProofFailure, "cleanup failed"):
            runner.run("rung-rvps")
        edit.restore.assert_not_called()
        self.assertNotIn("positive-recovery", events)
        self.assertEqual(runner.evidence["restoration"], "FAIL")

    def test_the_plan_marks_the_tests_all_runs(self):
        out = io.StringIO()
        with patch.object(sys, "argv", ["run-proofs.py", "--list"]), contextlib.redirect_stdout(out):
            self.assertEqual(0, suite.main())
        marked = {line.split()[1] for line in out.getvalue().splitlines() if line.startswith("  * ")}
        self.assertEqual(set(suite.DEFAULT_CASES), marked)
        self.assertIn("    rung-encrypted  ", out.getvalue())

    def test_cleanup_failure_is_failed_report_with_lock_retained(self):
        runner, edit, _ = self.fixture()
        runner.preflight = Mock(return_value={"fixture": True})
        runner.delete_pod.side_effect = Incomplete("simulated deletion timeout")
        lock = Mock()
        with tempfile.TemporaryDirectory(prefix="coco-proof-failure-") as directory:
            with patch.object(suite, "Runner", return_value=runner), patch.object(suite, "ProofLock", return_value=lock), \
                    patch.object(suite, "state_directory", return_value=Path(directory)), \
                    patch.object(suite, "restart_trustee"), \
                    patch.object(suite.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "fixture-revision\n", "")), \
                    patch.object(sys, "argv", ["run-proofs.py", "rung-rvps"]), contextlib.redirect_stdout(io.StringIO()):
                status = suite.main()
            report = json.loads(next(Path(directory).rglob("results.json")).read_text())
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["cases"][0]["evidence"]["restoration"], "FAIL")
        self.assertIn("coco-proof-lock", report["retainedLock"])
        lock.acquire.assert_called_once()
        lock.release.assert_not_called()
        edit.restore.assert_not_called()


if __name__ == "__main__":
    unittest.main()


class FakeWorker:
    """The worker cluster for the isolation case: probe outputs, pods and their deletion."""
    context = "fixture-worker"

    def __init__(self, node="private 401\npublic-address blocked\npublic-name blocked\n",
                 pod="private 404\npublic-address blocked\npublic-name blocked\n", guest_exit=0):
        self.outputs = {"node": node, "pod": pod}
        self.guest_exit, self.pods, self.deleted = guest_exit, {}, []

    def call(self, *args, data=None, optional=False):
        if args[0] == "debug":
            return self.outputs["node"]
        if args[0] == "create":
            self.pods[data["metadata"]["name"]] = data
            return ""
        if args[0] == "logs":
            return self.outputs["pod"]
        if args[:2] == ("get", "pod"):
            name = args[2]
            return "" if name in self.deleted or name not in self.pods else json.dumps(self.live(name))
        if args[0] == "delete":
            self.deleted.append(args[2])
            return ""
        raise AssertionError(f"unexpected oc call {args}")

    def live(self, name):
        pod = self.pods[name]
        status = {"phase": "Succeeded", "containerStatuses": []}
        if name.endswith("isolation-guest"):
            status = {"phase": "Succeeded" if self.guest_exit == 0 else "Failed",
                      "containerStatuses": [{"name": "app", "state": {"terminated": {"exitCode": self.guest_exit}}}]}
        elif name.endswith("isolation-exec"):
            status = {"phase": "Running", "containerStatuses": [{"name": "app", "ready": True, "state": {"running": {"startedAt": "2026-10-28T00:00:00Z"}}}]}
        return {"metadata": {**pod["metadata"], "uid": "uid-" + name}, "spec": pod["spec"], "status": status}

    def get(self, kind, name="", namespace=""):
        return self.live(name)


class ProofIsolation(unittest.TestCase):
    def runner(self, worker, exec_result=None):
        runner = suite.Runner({"WORKER_CONTEXT": "fixture-worker", "TRUSTEE_CONTEXT": "fixture-worker",
                               "TRUSTEE_LAB": "1", "PROOF_NODE": "node-a"}, Path("/tmp"))
        runner.worker = worker

        def render(case, suffix, **overrides):
            return {"apiVersion": "v1", "kind": "Pod",
                    "metadata": {"name": f"proof-{runner.id}-{suffix}", "namespace": runner.ns,
                                 "labels": {"coco.openshift.io/proof-run": runner.id}},
                    "spec": {"runtimeClassName": "kata-cc", "containers": [{"name": "app", "command": ["sleep", "3600"]}]}}

        runner.render = render
        refused = exec_result or subprocess.CompletedProcess([], 1, "", "ExecProcessRequest is blocked by policy")
        return runner, patch.object(suite.subprocess, "run", return_value=refused)

    def test_every_layer_blocked_with_a_private_answer_passes_and_removes_its_pods(self):
        worker = FakeWorker()
        runner, exec_patch = self.runner(worker)
        with exec_patch as run:
            runner.run("isolation")
        isolation = runner.evidence["isolation"]
        self.assertEqual({"private": "401", "publicAddress": "blocked", "publicName": "blocked"}, isolation["node"])
        self.assertEqual("404", isolation["ordinary pod"]["private"])
        self.assertEqual({"phase": "Succeeded", "exitCode": 0}, isolation["confidential guest"])
        self.assertEqual({"exitCode": 1, "blockedByPolicy": True}, isolation["exec"])
        self.assertEqual(sorted(worker.pods), sorted(worker.deleted))
        self.assertIn("exec", run.call_args.args[0])
        # The ordinary pod meets PodSecurity restricted, so it prints no warnings.
        probe = next(p for n, p in worker.pods.items() if n.endswith("isolation-pod"))
        self.assertTrue(probe["spec"]["securityContext"]["runAsNonRoot"])
        self.assertEqual(["ALL"], probe["spec"]["containers"][0]["securityContext"]["capabilities"]["drop"])
        self.assertEqual(["/bin/sh", "-c"], worker.pods[f"proof-{runner.id}-isolation-guest"]["spec"]["containers"][0]["command"][:2])

    def test_a_blocked_result_needs_a_private_answer(self):
        runner, exec_patch = self.runner(FakeWorker(node="private 000\npublic-address blocked\npublic-name blocked\n"))
        with exec_patch, self.assertRaisesRegex(Incomplete, "private destination did not answer from the node"):
            runner.run("isolation")

    def test_reachable_public_destinations_fail(self):
        runner, exec_patch = self.runner(FakeWorker(pod="private 404\npublic-address reachable\npublic-name blocked\n"))
        with exec_patch, self.assertRaisesRegex(ProofFailure, "publicAddress reachable from the ordinary pod"):
            runner.run("isolation")
        for code, error, text in ((11, ProofFailure, "a public address is reachable"),
                                  (12, ProofFailure, "a public name is reachable"),
                                  (10, Incomplete, "the private destination did not answer")):
            with self.subTest(guest_exit=code):
                runner, exec_patch = self.runner(FakeWorker(guest_exit=code))
                with exec_patch, self.assertRaisesRegex(error, text):
                    runner.run("isolation")

    def test_exec_into_the_guest_must_be_refused_by_the_agent_policy(self):
        runner, exec_patch = self.runner(FakeWorker(), subprocess.CompletedProcess([], 0, "", ""))
        with exec_patch, self.assertRaisesRegex(ProofFailure, "exec into the confidential guest succeeded"):
            runner.run("isolation")
        runner, exec_patch = self.runner(FakeWorker(), subprocess.CompletedProcess([], 1, "", "connection refused"))
        with exec_patch, self.assertRaisesRegex(Incomplete, "not with the agent policy's refusal"):
            runner.run("isolation")

    def test_all_includes_isolation_last(self):
        self.assertEqual("isolation", suite.DEFAULT_CASES[-1])
        self.assertIn("isolation", suite.CASES)
