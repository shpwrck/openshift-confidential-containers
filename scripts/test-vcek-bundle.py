#!/usr/bin/env python3
"""VCEK provenance regressions using ephemeral synthetic certificates, no KDS."""
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vcek_bundle", ROOT / "scripts/lib/vcek_bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class VcekProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "bundle"
        self.input = self.root / "input"
        self.cert = self.root / "new.der"
        self.cert.write_bytes(self.certificate())

    @staticmethod
    def certificate(expired=False):
        # Key material exists only in memory; these are test certificates, not AMD endorsements.
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "synthetic-provenance-test")])
        now = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - timedelta(days=2))
                .not_valid_after(now + timedelta(days=-1 if expired else 1))
                .sign(key, hashes.SHA256()))
        return cert.public_bytes(serialization.Encoding.DER)

    def request(self, content, kind="url"):
        self.input.write_bytes(content)
        return bundle.request(self.directory, kind, self.input)

    def publish(self, content=b"https://kdsintf.amd.com/vcek/v1/Milan/test?blSPL=1\n", kind="url"):
        source = self.request(content, kind)
        bundle.publish(self.directory, self.cert, source)
        return source

    def test_unchanged_url_can_reuse_valid_certificate(self):
        source = self.publish()
        self.assertEqual(source, bundle.current(self.directory)["sourceSha256"])
        self.request(self.input.read_bytes())
        bundle.current(self.directory)

    def test_changed_tcb_url_invalidates_cached_der_and_preserves_history(self):
        self.publish()
        old_url = (self.directory / "vcek.url").read_bytes()
        old_der = (self.directory / "vcek.der").read_bytes()
        source = self.request(old_url.replace(b"blSPL=1", b"blSPL=2"))
        with self.assertRaisesRegex(ValueError, "refresh required"):
            bundle.current(self.directory)
        historical = self.directory / "history" / bundle.digest(old_der)
        self.assertEqual(old_der, (historical / "vcek.der").read_bytes())
        self.assertEqual(old_url, (historical / "vcek.url").read_bytes())
        self.cert.write_bytes(self.certificate())
        bundle.publish(self.directory, self.cert, source)
        self.assertEqual(source, bundle.current(self.directory)["sourceSha256"])

    def test_changed_report_invalidates_even_when_chip_id_unchanged(self):
        report = bytearray(1184)
        report[416:480] = b"x" * 64
        self.publish(bytes(report), "report")
        report[384] = 2  # Changed TCB bytes, same CHIP_ID.
        self.request(bytes(report), "report")
        with self.assertRaisesRegex(ValueError, "refresh required"):
            bundle.current(self.directory)

    def test_request_changed_during_fetch_cannot_publish(self):
        first = self.publish()
        self.request(b"https://kdsintf.amd.com/new-tcb")
        with self.assertRaisesRegex(ValueError, "changed during download"):
            bundle.publish(self.directory, self.cert, first)

    def test_invalid_download_preserves_previous_der(self):
        source = self.publish()
        previous = (self.directory / "vcek.der").read_bytes()
        self.cert.write_bytes(b"not a certificate")
        with self.assertRaises(ValueError):
            bundle.publish(self.directory, self.cert, source)
        self.assertEqual(previous, (self.directory / "vcek.der").read_bytes())
        bundle.current(self.directory)

    def test_expired_certificate_cannot_be_published(self):
        source = self.request(b"https://kdsintf.amd.com/test")
        self.cert.write_bytes(self.certificate(expired=True))
        with self.assertRaisesRegex(ValueError, "expired"):
            bundle.publish(self.directory, self.cert, source)
        self.assertFalse((self.directory / "vcek.der").exists())

    def test_untracked_legacy_der_is_not_accepted_as_current(self):
        self.request(b"https://kdsintf.amd.com/test")
        (self.directory / "vcek.der").write_bytes(self.cert.read_bytes())
        with self.assertRaises(OSError):
            bundle.current(self.directory)

    def test_replaced_valid_der_still_requires_matching_digest(self):
        self.publish()
        (self.directory / "vcek.der").write_bytes(self.certificate())
        with self.assertRaisesRegex(ValueError, "provenance"):
            bundle.current(self.directory)

    def test_report_overwritten_outside_request_is_detected(self):
        self.publish(b"report-one", "report")
        (self.directory / "report.bin").write_bytes(b"report-two")
        with self.assertRaisesRegex(ValueError, "input changed"):
            bundle.current(self.directory)


if __name__ == "__main__":
    unittest.main()
