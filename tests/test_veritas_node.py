"""Run NODE Veritas orchestration against local oc/podman stubs; no cluster/network."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
AUTH_MARKER = "synthetic-node-veritas-auth-only"

MOCK_OC = r'''#!/usr/bin/env python3
import json, os, pathlib, stat, subprocess, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ["FIXTURE_STATE"])
with (base / "oc-calls.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\n")
assert args[0] == "--context=fixture-worker", args
assert args[1].startswith("--request-timeout="), args
args = args[2:]
if args == ["whoami"]:
    print("fixture-user")
    raise SystemExit(0)
assert args[0] == "debug", args
assert "--no-stdin=false" in args and "--no-tty" in args, args
assert "node/fixture-snp-node" in args, args
assert args[-4:] == ["chroot", "/host", "bash", "-s"], args
body = sys.stdin.read()
(base / "stdin-script").write_text(body)
(base / "stdin-mode").write_text(str(stat.S_IMODE(os.fstat(0).st_mode)))
# Emulate only the streamed bash script. Never execute chroot, a real oc or a container.
# The simulated node is RHCOS and uses GNU base64 even when the controller is
# macOS. Scope this emulator to the node subprocess; the host retains its real
# base64 command, including the controller's BSD decode/encode compatibility.
node_bin = base / "node-bin"
node_bin.mkdir(exist_ok=True)
(node_bin / "base64").write_text("""#!/usr/bin/env python3
import base64, pathlib, sys
args = sys.argv[1:]
if args == ['-d']:
    sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))
elif len(args) == 2 and args[0] == '-w0':
    sys.stdout.buffer.write(base64.b64encode(pathlib.Path(args[1]).read_bytes()))
else:
    raise SystemExit('unexpected node base64 arguments: ' + repr(args))
""")
(node_bin / "base64").chmod(0o755)
node_env = dict(os.environ, PATH=str(node_bin) + os.pathsep + os.environ['PATH'])
result = subprocess.run(["bash", "-s"], input=body, env=node_env, text=True, capture_output=True)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
'''

MOCK_PODMAN = r'''#!/usr/bin/env python3
import json, os, pathlib, stat, sys
import yaml
args = sys.argv[1:]
assert args[:3] == ["run", "--rm", "--privileged"], args
base = pathlib.Path(os.environ["FIXTURE_STATE"])
work = pathlib.Path(next(a.removesuffix(":/work:z") for a in args if a.endswith(":/work:z")))
secret = work / "pull-secret.json"
initdata = work / "initdata.toml"
report = {"argv": args, "work": str(work), "workMode": stat.S_IMODE(work.stat().st_mode),
          "secretMode": stat.S_IMODE(secret.stat().st_mode), "secret": secret.read_text(),
          "initdataMode": stat.S_IMODE(initdata.stat().st_mode), "initdata": initdata.read_text(),
          "registries": (work / "registries.conf").read_text(),
          "wrapper": (work / "bin/oc").read_text()}
(base / "node-report.json").write_text(json.dumps(report))
mode = os.environ.get("FIXTURE_VERITAS_MODE", "valid")
if mode == "command-failure":
    print("fixture Veritas command failed", file=sys.stderr)
    raise SystemExit(7)
record = {"version": "0.1.0", "name": "snp_launch_measurement",
          "expiration": "2099-01-01T00:00:00Z", "value": ["a" * 96]}
if mode == "expired":
    record["expiration"] = "2000-01-01T00:00:00Z"
if mode == "malformed":
    del record["value"]
    record["hash-value"] = [{"alg": "sha384", "value": "abc"}]
output = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "legacy-veritas-name"},
          "data": {"reference-values.json": json.dumps([record])}}
(work / "out/rvps-reference-values.yaml").write_text(yaml.safe_dump(output))
print("fixture Veritas complete", file=sys.stderr)
'''


class NodeVeritasTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="coco-veritas-node-test-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.repo, self.state, self.bin = (self.base / name for name in ("repo", "state", "bin"))
        (self.repo / "scripts/lib").mkdir(parents=True)
        self.state.mkdir(mode=0o700)
        self.bin.mkdir()
        # The artifact-resolution gate is covered by release/proof tests. This
        # fixture isolates the post-gate node transport using unchanged production scripts.
        for path in ("scripts/gen-rvps-veritas.sh", "scripts/lib/cluster-context.sh", "scripts/lib/trustee_config.py"):
            shutil.copyfile(ROOT / path, self.repo / path)
        (self.repo / "scripts/lib/release.sh").write_text(
            "load_release_defaults() { :; }\nrequire_resolved_release() { :; }\n")
        for name, body in (("oc", MOCK_OC), ("podman", MOCK_PODMAN)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.secret = json.dumps({"auths": {"registry.fixture.invalid": {"auth": AUTH_MARKER}}})
        (self.state / "pull-secret.json").write_text(self.secret)
        (self.state / "pull-secret.json").chmod(0o600)
        self.initdata = 'algorithm = "sha256"\nversion = "0.1.0"\n[data]\n'
        (self.state / "initdata.toml").write_text(self.initdata)
        (self.state / "registries.conf").write_text('unqualified-search-registries = []\n')
        (self.state / "oc-wrapper").write_text('#!/bin/sh\nexit 0\n')
        self.output = self.state / "rvps-snp.yaml"
        self.env = {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"], "HOME": str(self.state),
                    "COCO_STATE_DIR": str(self.state), "FIXTURE_STATE": str(self.state),
                    "PULL_SECRET": str(self.state / "pull-secret.json"), "TEE": "snp", "NODE": "fixture-snp-node",
                    "WORKER_CONTEXT": "fixture-worker", "OCP_VERSION": "4.20.39",
                    "TOOLS_IMG": "registry.fixture.invalid/coco-tools@sha256:" + "a" * 64,
                    "DEBUG_IMAGE": "registry.fixture.invalid/debug@sha256:" + "b" * 64,
                    "REGISTRIES_CONF": str(self.state / "registries.conf"),
                    "VERITAS_OC_WRAPPER": str(self.state / "oc-wrapper"),
                    "TRUSTEE_NAME": "selected-trustee", "TRUSTEE_NS": "selected-trustee-namespace"}

    def run_veritas(self):
        return subprocess.run(["bash", str(self.repo / "scripts/gen-rvps-veritas.sh")], cwd=self.repo,
                              env=self.env, capture_output=True, text=True, check=False, timeout=30)

    def test_node_stream_uses_explicit_context_and_protected_inputs(self):
        result = self.run_veritas()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.state / "oc-calls.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(call[0] == "--context=fixture-worker" for call in calls))
        debug = calls[1]
        self.assertEqual(debug[-4:], ["chroot", "/host", "bash", "-s"])
        script = (self.state / "stdin-script").read_text()
        encoded_auth = base64.b64encode(self.secret.encode()).decode()
        self.assertIn(encoded_auth, script)
        for content in (AUTH_MARKER, self.secret, encoded_auth, script):
            self.assertNotIn(content, json.dumps(calls))
            self.assertNotIn(content, result.stdout + result.stderr)
        self.assertEqual(int((self.state / "stdin-mode").read_text()), 0o600)
        node = json.loads((self.state / "node-report.json").read_text())
        self.assertEqual(node["secret"], self.secret)
        self.assertEqual(node["initdata"], self.initdata)
        self.assertEqual(node["workMode"], 0o700)
        self.assertEqual(node["secretMode"], 0o600)
        self.assertEqual(node["initdataMode"], 0o600)
        self.assertEqual(node["registries"], (self.state / "registries.conf").read_text())
        self.assertEqual(node["wrapper"], (self.state / "oc-wrapper").read_text())
        self.assertNotIn(encoded_auth, json.dumps(node["argv"]))
        self.assertFalse(Path(node["work"]).exists(), "node-side EXIT trap must remove protected inputs")
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertTrue(all(log.stat().st_mode & 0o777 == 0o600 for log in self.state.glob("rvps-snp.yaml.log.*")))

    def test_node_output_is_converted_by_actual_target_validator(self):
        result = self.run_veritas()
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(self.output.read_text())
        self.assertEqual(document["metadata"], {"name": "selected-trustee-rvps-reference-values", "namespace": "selected-trustee-namespace"})
        self.assertEqual(set(document["data"]), {"reference_value"})
        records = json.loads(document["data"]["reference_value"])
        record = json.loads(base64.b64decode(records["snp_launch_measurement"]))
        self.assertEqual(record["value"], ["a" * 96])
        self.assertEqual(record["expiration"], "2099-01-01T00:00:00Z")

    def test_reviewed_kernel_cmdline_is_one_literal_argument(self):
        cmdline = "tsc=reliable nr_cpus=1 agent.launch_process_timeout=6"
        self.env["VERITAS_KERNEL_CMDLINE"] = cmdline
        result = self.run_veritas()
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads((self.state / "node-report.json").read_text())["argv"]
        self.assertEqual(argv[argv.index("--kernel-cmdline") + 1], cmdline)

    def test_command_or_validation_failure_preserves_last_good_output(self):
        failures = {
            "command-failure": "Veritas failed on selected node",
            "expired": "RVPS record is expired or lacks a timezone: snp_launch_measurement",
            "malformed": "RVPS record lacks a nonempty value: snp_launch_measurement",
        }
        for mode, expected_error in failures.items():
            with self.subTest(mode=mode):
                self.output.write_text("last known-good output\n")
                self.env["FIXTURE_VERITAS_MODE"] = mode
                result = self.run_veritas()
                self.assertNotEqual(result.returncode, 0)
                # A transport failure must not satisfy a validator-failure case.
                self.assertIn(expected_error, result.stderr)
                self.assertEqual(self.output.read_text(), "last known-good output\n")
                self.assertNotIn(AUTH_MARKER, result.stdout + result.stderr)
                node = json.loads((self.state / "node-report.json").read_text())
                self.assertFalse(Path(node["work"]).exists())

    def test_missing_context_stops_before_any_oc_command(self):
        del self.env["WORKER_CONTEXT"]
        result = self.run_veritas()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WORKER_CONTEXT", result.stderr)
        self.assertFalse((self.state / "oc-calls.jsonl").exists())

    def test_output_inside_checkout_is_rejected_before_any_oc_command(self):
        self.env["OUT"] = str(self.repo / "rvps.yaml")
        result = self.run_veritas()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the checkout", result.stderr)
        self.assertFalse((self.state / "oc-calls.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
