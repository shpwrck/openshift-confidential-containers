"""Exercise lab seeding with a filesystem-only oc stub and synthetic credentials."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_trustee_config import CPU

ROOT = Path(__file__).resolve().parents[1]
# No command below can reach a real cluster. The release boundary is separately
# tested by test-release.py; this isolated fixture exercises post-gate behavior.
MOCK_OC = '''#!/usr/bin/env python3
import base64, json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as f:
    f.write(json.dumps(args) + "\\n")
while args and (args[0] in ("--context", "-n") or args[0].startswith("--request-timeout=")):
    if args[0].startswith("--request-timeout="):
        args = args[1:]
    else:
        args = args[2:]
statefile = pathlib.Path(os.environ["MOCK_STATE"])
state = json.loads(statefile.read_text())
if args == ["whoami"]:
    print("offline-test")
elif args[:2] == ["get", "trusteeconfig"]:
    print(json.dumps({"spec": {"profileType": os.environ.get("MOCK_PROFILE", "Permissive")}}))
elif args[:3] == ["create", "secret", "generic"]:
    data = {}
    for option in args[4:]:
        if option.startswith("--from-file="):
            key, filename = option[len("--from-file="):].split("=", 1)
            data[key] = base64.b64encode(pathlib.Path(filename).read_bytes()).decode()
    print(json.dumps({"metadata": {"name": args[3]}, "data": data}))
elif args[:2] == ["get", "secret"]:
    assert "name" in args, "tests forbid Secret-value reads"
    if args[2] in state:
        print("secret/" + args[2])
elif args[:2] == ["patch", "secret"]:
    patch = json.loads(pathlib.Path(args[args.index("--patch-file") + 1]).read_text())
    assert set(patch) == {"data"}, "patch must only touch supplied resource keys"
    state[args[2]].update(patch["data"])
    statefile.write_text(json.dumps(state))
elif args[:2] == ["create", "-f"]:
    manifest = json.loads(pathlib.Path(args[2]).read_text())
    assert manifest["metadata"]["name"] not in state
    state[manifest["metadata"]["name"]] = manifest["data"]
    statefile.write_text(json.dumps(state))
else:
    raise SystemExit("unexpected mocked oc command: " + repr(args))
'''


class TrusteeCliTests(unittest.TestCase):
    def setUp(self):
        self.repo_tmp = tempfile.TemporaryDirectory(prefix="coco-trustee-test-repo-")
        self.data_tmp = tempfile.TemporaryDirectory(prefix="coco-trustee-test-data-")
        self.addCleanup(self.repo_tmp.cleanup)
        self.addCleanup(self.data_tmp.cleanup)
        self.repo = Path(self.repo_tmp.name) / "repo"
        self.data = Path(self.data_tmp.name)
        (self.repo / "scripts/lib").mkdir(parents=True)
        for path in ("scripts/seed-trustee-secrets.sh", "scripts/lib/compat.sh"):
            shutil.copyfile(ROOT / path, self.repo / path)
        (self.repo / "scripts/lib/release.sh").write_text(
            "# Offline test fixture: artifact validation has its own tests.\n"
            "load_release_defaults() { :; }\nrequire_resolved_release() { :; }\n")
        (self.data / "oc").write_text(MOCK_OC)
        (self.data / "oc").chmod(0o755)
        (self.data / "state.json").write_text(json.dumps({"security-policy": {"rung-signed": "cHJlc2VydmU="}}))
        (self.data / "calls.jsonl").touch()
        (self.data / "password").write_text("synthetic-offline-fixture")
        (self.data / "ca.crt").write_text("synthetic public certificate fixture")
        vcek = self.data / "vcek-bundle" / ("a" * 128)
        vcek.mkdir(parents=True)
        (vcek / "vcek.der").write_bytes(b"synthetic public certificate fixture")
        self.env = {"PATH": str(self.data) + os.pathsep + os.environ["PATH"], "HOME": str(self.data),
                    "MOCK_STATE": str(self.data / "state.json"), "MOCK_CALLS": str(self.data / "calls.jsonl"),
                    "TEE": "snp", "TRUSTEE_PROFILE": "Permissive", "TRUSTEE_LAB": "1",
                    "TRUSTEE_CONTEXT": "fixture-trustee-context", "MIRROR_PASSWORD_FILE": str(self.data / "password"),
                    "MIRROR_CA": str(self.data / "ca.crt"), "VCEK_BUNDLE": str(self.data / "vcek-bundle"), "HWIDS": "a" * 128}

    def run_seed(self):
        return subprocess.run(["bash", str(self.repo / "scripts/seed-trustee-secrets.sh")],
                              env=self.env, capture_output=True, text=True, check=False)

    def test_customer_default_exits_before_any_cluster_command(self):
        del self.env["TRUSTEE_PROFILE"]
        result = self.run_seed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provision customer resources out of band", result.stderr)
        self.assertEqual((self.data / "calls.jsonl").read_text(), "")

    def test_lab_flag_cannot_seed_an_existing_restricted_config(self):
        self.env["MOCK_PROFILE"] = "Restricted"
        result = self.run_seed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("intended Permissive", result.stderr)
        self.assertEqual(json.loads((self.data / "state.json").read_text()), {"security-policy": {"rung-signed": "cHJlc2VydmU="}})

    def test_plain_rerun_preserves_signed_policy_key_and_resource_identity(self):
        for _ in range(2):
            result = self.run_seed()
            self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.data / "state.json").read_text())
        self.assertEqual(state["security-policy"]["rung-signed"], "cHJlc2VydmU=")
        self.assertIn("test", state["credential"])
        self.assertIn("secret", state["sample"])
        self.assertIn("status", state["attestation-status"])
        self.assertNotIn("kbs-auth-public-key", state)
        self.assertEqual(len([key for key in state if key.startswith("vcek-")]), 1)
        calls = [json.loads(line) for line in (self.data / "calls.jsonl").read_text().splitlines()]
        self.assertTrue(all(c[:2] == ["--context", "fixture-trustee-context"] for c in calls))
        self.assertTrue(any("patch" in c and "security-policy" in c for c in calls))
        credential = json.loads(base64.b64decode(state["credential"]["test"]))
        self.assertIn("mirror.rig.local:8443", credential["auths"])

    def test_measured_renderer_preserves_cpu_checks_and_emits_no_resource_policy(self):
        base, initdata = self.data / "cpu.rego", self.data / "initdata.toml"
        base.write_text(CPU)
        initdata.write_text('version = "0.1.0"\nalgorithm = "sha256"\n[data]\n')
        env = {**self.env, "TEE": "snp", "BASE_CPU_POLICY_FILE": str(base), "CPU_CONFIGMAP_NAME": "actual-cpu-policy"}
        command = ["bash", str(ROOT / "scripts/render-measurement-policy.sh"), str(initdata)]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = json.loads(result.stdout)
        self.assertEqual(rendered["metadata"]["name"], "actual-cpu-policy")
        self.assertEqual(set(rendered["data"]), {"default_cpu.rego"})
        self.assertIn('input.snp.measurement in query_reference_value("snp_launch_measurement")', rendered["data"]["default_cpu.rego"])
        self.assertIn('"configuration": coco_bound_configuration,', rendered["data"]["default_cpu.rego"])
        base.write_text(CPU.replace("default hardware := 97", "default hardware := 2"))
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_secret_input_under_checkout_is_refused_before_cluster_access(self):
        self.env["MIRROR_PASSWORD_FILE"] = str(self.repo / "do-not-read")
        result = self.run_seed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside Homelab", result.stderr)
        self.assertEqual((self.data / "calls.jsonl").read_text(), "")


if __name__ == "__main__":
    unittest.main()
