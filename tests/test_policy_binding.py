"""Execute the initdata extension with OPA; preserve vendor TCB/launch/config gates."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_trustee_config import CPU

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from proof_core import bind_initdata_policy

# The lookup stub supplies the same typed reference values used by the fixture's
# SNP CPU checks. It replaces only the Trustee runtime extension in offline OPA.
REFERENCE_STUB = '\nquery_reference_value(name) := data.references[name]\n'
RESOURCE_POLICY = '''package resource_fixture
import rego.v1
default allow := false
allow if {
  every claim in ["hardware", "executables", "configuration"] {
    value := data.policy.trust_claims[claim]
    value >= 2
    value <= 31
  }
}
'''


class InitdataPolicyExecution(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fallback = Path(os.environ.get("COCO_STATE_DIR", str(Path.home() / ".local/state/openshift-confidential-containers"))) / "dev-bin/opa"
        cls.opa = shutil.which("opa") or (str(fallback) if fallback.is_file() and os.access(fallback, os.X_OK) else None)
        if cls.opa is None:
            raise RuntimeError("OPA is required: run make install-dev-tools and add its dev-bin to PATH")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="coco-opa-binding-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.input = {"init_data": "a" * 64, "snp": {
            "measurement": "approved-launch", "reported_tcb_bootloader": 1,
            "reported_tcb_microcode": 2, "reported_tcb_snp": 3,
            "reported_tcb_tee": 4, "policy_debug_allowed": False}}
        refs = {"snp_launch_measurement": ["approved-launch"], "snp_bootloader": [1],
                "snp_microcode": [2], "snp_snp_svn": [3], "snp_tee_svn": [4]}
        (self.path / "references.json").write_text(json.dumps({"references": refs}))
        (self.path / "cpu.rego").write_text(bind_initdata_policy(CPU, "a" * 64) + REFERENCE_STUB)
        (self.path / "resource.rego").write_text(RESOURCE_POLICY)

    def evaluate(self, claims):
        (self.path / "input.json").write_text(json.dumps(claims))
        result = subprocess.run([self.opa, "eval", "--format=json", "--fail",
                                 "--data", str(self.path / "cpu.rego"), "--data", str(self.path / "resource.rego"),
                                 "--data", str(self.path / "references.json"), "--input", str(self.path / "input.json"),
                                 '{"allow": data.resource_fixture.allow, "claims": data.policy.trust_claims}'],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return json.loads(result.stdout)["result"][0]["expressions"][0]["value"]

    def test_approved_digest_with_vendor_checks_passing_is_affirmative(self):
        result = self.evaluate(self.input)
        self.assertTrue(result["allow"])
        self.assertEqual(result["claims"], {"hardware": 2, "executables": 3, "configuration": 3})

    def test_initdata_tamper_is_denied_with_vendor_checks_still_passing(self):
        claims = copy.deepcopy(self.input)
        claims["init_data"] = "b" * 64
        result = self.evaluate(claims)
        self.assertFalse(result["allow"])
        self.assertEqual(result["claims"]["hardware"], 2)
        self.assertEqual(result["claims"]["executables"], 3)
        self.assertEqual(result["claims"]["configuration"], 36)

    def test_approved_digest_cannot_override_vendor_failures(self):
        for field, value, failed_claim, expected in (
            ("reported_tcb_microcode", 99, "hardware", 97),
            ("measurement", "unapproved-launch", "executables", 33),
            ("policy_debug_allowed", True, "configuration", 36),
        ):
            with self.subTest(field=field):
                claims = copy.deepcopy(self.input)
                claims["snp"][field] = value
                result = self.evaluate(claims)
                self.assertFalse(result["allow"])
                self.assertEqual(result["claims"][failed_claim], expected)


if __name__ == "__main__":
    unittest.main()
