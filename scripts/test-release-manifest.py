#!/usr/bin/env python3
"""Hardware-free regression tests for release drift and unsafe readiness claims."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_validator", ROOT / "scripts/verify-release.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class ReleaseContractTests(unittest.TestCase):
    def setUp(self):
        self.bom = json.loads((ROOT / "install/release-manifest.json").read_text())
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ["install/imageset-config.yaml", "gitops/base/operators/subscriptions.yaml", "gitops/base/gatekeeper/operator.yaml"]:
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, destination)

    def check(self, tee="snp", resolved=False, env=None):
        return validator.validate(self.bom, self.root, tee, resolved, env or {})

    def test_snp_profile_agrees_without_claiming_readiness(self):
        self.assertEqual([], self.check("snp"))

    def test_candidate_artifacts_block_deployment(self):
        self.bom["images"]["cocoTools"]["resolution"] = "candidate"
        errors = self.check(resolved=True)
        self.assertTrue(any("unresolved operators.osc" in x for x in errors))
        self.assertTrue(any("unresolved images.cocoTools" in x for x in errors))

    def test_baseline_version_cannot_satisfy_target_floor(self):
        self.bom["platform"]["version"] = "4.20.18"
        self.assertTrue(any("compatibility matrix" in x for x in self.check()))

    def test_image_set_pin_drift_is_rejected(self):
        path = self.root / "install/imageset-config.yaml"
        path.write_text(path.read_text().replace("4.20.39", "4.20.38"))
        self.assertTrue(any("platform pin" in x for x in self.check()))

    def test_explicit_override_is_not_silently_accepted(self):
        self.assertTrue(any("OCP_VERSION override" in x for x in self.check(env={"OCP_VERSION":"4.20.18"})))

    def test_supporting_operator_channels_cannot_drift(self):
        path = self.root / "install/imageset-config.yaml"
        path.write_text(path.read_text().replace("stable-v1", "unreviewed-channel"))
        self.assertTrue(any("certManager channel differs" in x for x in self.check()))

    def test_resolved_supporting_operator_versions_must_be_mirrored(self):
        import yaml
        path = self.root / "install/imageset-config.yaml"
        document = yaml.safe_load(path.read_text())
        for key in ("nfd", "certManager", "gatekeeper"):
            op = self.bom["operators"][key]
            op["version"] = "0.0.1"  # synthetic resolver fixture
            self.assertTrue(any(f"{key} pin differs" in x for x in self.check()))
            package = next(p for p in document["mirror"]["operators"][0]["packages"] if p["name"] == op["package"])
            package["channels"][0].update(minVersion=op["version"], maxVersion=op["version"])
            path.write_text(yaml.safe_dump(document))
        self.assertEqual([], self.check())

    def test_missing_supporting_operator_is_rejected(self):
        import yaml
        path = self.root / "install/imageset-config.yaml"
        document = yaml.safe_load(path.read_text())
        document["mirror"]["operators"][0]["packages"] = [p for p in document["mirror"]["operators"][0]["packages"] if p["name"] != "nfd"]
        path.write_text(yaml.safe_dump(document))
        self.assertTrue(any("missing package operators.nfd" in x for x in self.check()))

    def test_subscription_cannot_float_automatically(self):
        path = self.root / "gitops/base/operators/subscriptions.yaml"
        path.write_text(path.read_text().replace("installPlanApproval: Manual", "installPlanApproval: Automatic"))
        self.assertTrue(any("InstallPlan approval" in x for x in self.check()))

    def test_loader_preserves_override_and_reports_missing_bom(self):
        command = 'source scripts/lib/release.sh; load_release_defaults; printf "%s" "$OCP_VERSION"'
        result = subprocess.run(["bash", "-c", command], cwd=ROOT, env={"PATH":"/usr/local/bin:/usr/bin:/bin", "OCP_VERSION":"4.20.18"}, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("4.20.18", result.stdout)
        result = subprocess.run(["bash", "-c", "source scripts/lib/release.sh; load_release_defaults"], cwd=ROOT, env={"PATH":"/usr/local/bin:/usr/bin:/bin", "RELEASE_MANIFEST":str(self.root / "missing.json")}, capture_output=True, text=True)
        self.assertNotEqual(0, result.returncode)


if __name__ == "__main__":
    unittest.main()
