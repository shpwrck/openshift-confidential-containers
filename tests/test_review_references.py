#!/usr/bin/env python3
"""Reviewed SNP reference set: Veritas records plus VCEK TCB levels, offline only."""
import base64
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/review-references.py"
sys.path.insert(0, str(ROOT / "scripts/lib"))
spec = importlib.util.spec_from_file_location("review_references", SCRIPT)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
import vcek_bundle  # noqa: E402

HWID = "ab" * 64
URL = f"https://kdsintf.amd.com/vcek/v1/Genoa/{HWID}?blSPL=9&teeSPL=0&snpSPL=23&ucodeSPL=72\n"


def certificate():
    # Key material exists only in memory; this is a test certificate, not an AMD endorsement.
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "synthetic-reference-test")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1))
            .sign(key, hashes.SHA256()))
    return cert.public_bytes(serialization.Encoding.DER)


def record(name, value):
    return {"version": "0.1.0", "name": name, "expiration": "2099-01-01T00:00:00Z", "value": value}


class ReviewReferencesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "vcek-bundle"
        self.collect(URL)
        self.generated = self.root / "rvps-generated.yaml"
        self.write_generated([record("snp_launch_measurement", ["a" * 96]), record("init_data", ["b" * 96])])

    def collect(self, url):
        source = self.root / "url"
        source.write_text(url)
        directory = self.bundle / HWID
        digest = vcek_bundle.request(directory, "url", source)
        cert = self.root / "vcek.der"
        cert.write_bytes(certificate())
        vcek_bundle.publish(directory, cert, digest)

    def write_generated(self, records):
        values = {r["name"]: base64.b64encode(json.dumps(r).encode()).decode() for r in records}
        self.generated.write_text(json.dumps({"apiVersion": "v1", "kind": "ConfigMap",
                                              "metadata": {"name": "trustee-config-rvps-reference-values",
                                                           "namespace": "trustee-operator-system"},
                                              "data": {"reference_value": json.dumps(values)}}))

    def decoded(self, configmap):
        values = json.loads(configmap["data"]["reference_value"])
        return {k: json.loads(base64.b64decode(v)) for k, v in values.items()}

    def test_adds_vcek_tcb_as_lists_and_drops_named_records(self):
        configmap, rows = review.review(self.generated, self.bundle, [HWID], ["init_data"])
        records = self.decoded(configmap)
        self.assertEqual(set(records), {"snp_launch_measurement", "snp_bootloader", "snp_tee_svn", "snp_snp_svn", "snp_microcode"})
        self.assertEqual(records["snp_bootloader"]["value"], [9])
        self.assertEqual(records["snp_tee_svn"]["value"], [0])
        self.assertEqual(records["snp_snp_svn"]["value"], [23])
        self.assertEqual(records["snp_microcode"]["value"], [72])
        self.assertEqual(records["snp_microcode"]["expiration"], "2099-01-01T00:00:00Z")
        self.assertEqual(records["snp_microcode"]["version"], "0.1.0")
        self.assertIn(("snp_microcode", "[72]", "2099-01-01T00:00:00Z", "VCEK URL ucodeSPL"), rows)

    def test_refuses_changed_url_missing_values_or_conflicts(self):
        with self.assertRaisesRegex(ValueError, "no init_dat record"):
            review.review(self.generated, self.bundle, [HWID], ["init_dat"])
        with self.assertRaisesRegex(ValueError, "HWIDS"):
            review.review(self.generated, self.bundle, [], [])
        self.write_generated([record("snp_launch_measurement", ["a" * 96]), record("snp_bootloader", [8])])
        with self.assertRaisesRegex(ValueError, "differs from the VCEK TCB"):
            review.review(self.generated, self.bundle, [HWID], [])
        self.collect(URL.replace("&ucodeSPL=72", ""))
        with self.assertRaisesRegex(ValueError, "ucodeSPL"):
            review.review(self.generated, self.bundle, [HWID], [])
        (self.bundle / HWID / "vcek.url").write_text(URL.replace("blSPL=9", "blSPL=10"))
        with self.assertRaisesRegex(ValueError, "changed after collection"):
            review.review(self.generated, self.bundle, [HWID], [])

    def test_cli_output_is_accepted_by_trustee_configure_validation(self):
        out = self.root / "rvps-reviewed.yaml"
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.generated), str(out), "--vcek-bundle", str(self.bundle),
                                 "--hwids", HWID.upper(), "--drop", "init_data"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("snp_snp_svn", result.stdout)
        self.assertEqual(out.stat().st_mode & 0o077, 0)
        check = subprocess.run([sys.executable, str(ROOT / "scripts/lib/trustee_config.py"), "rvps", "--file", str(out)],
                               text=True, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stderr)


if __name__ == "__main__":
    unittest.main()
