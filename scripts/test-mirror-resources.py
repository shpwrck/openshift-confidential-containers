#!/usr/bin/env python3
"""Offline regression tests for catalog naming, origin selection and immutable identity."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("normalize-mirror-resources.py")
SPEC = importlib.util.spec_from_file_location("mirror_resources", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SOURCE_DIGEST = "sha256:" + "1" * 64
MIRROR_DIGEST = "sha256:" + "2" * 64
ENDPOINT = "mirror.example:8443"
BOM = {"catalog": {"ref": "registry.redhat.io/redhat/redhat-operator-index@" + SOURCE_DIGEST,
                   "digest": SOURCE_DIGEST, "resolution": "verified", "source": "cs-redhat-operator-index-v4-20"}}
EXPECTED = ENDPOINT + "/redhat/redhat-operator-index:sha256-" + "1" * 64
PIN = ENDPOINT + "/redhat/redhat-operator-index@" + MIRROR_DIGEST


def docs():
    return [
        {"apiVersion": "config.openshift.io/v1", "kind": "ImageDigestMirrorSet", "metadata": {"name": "idms"}, "spec": {"imageDigestMirrors": []}},
        {"apiVersion": "operators.coreos.com/v1alpha1", "kind": "CatalogSource", "metadata": {"name": "cs-redhat-operator-index-sha256-111", "namespace": "openshift-marketplace"}, "spec": {"sourceType": "grpc", "image": EXPECTED}},
    ]


def info(ref):
    return {"name": ref, "digest": MIRROR_DIGEST, "contentDigest": MIRROR_DIGEST,
            "config": {"os": "linux", "architecture": "amd64", "config": {"Labels": {"operators.operatorframework.io.index.configs.v1": "/configs"}}}}


class MirrorResourceTests(unittest.TestCase):
    def test_expected_catalog_renamed_and_pinned_without_changing_other_resources(self):
        source = docs()
        calls = []
        def inspect(ref):
            calls.append(ref)
            return info(ref)
        result, evidence = MODULE.normalize(source, BOM, ENDPOINT, inspect)
        self.assertEqual(calls, [EXPECTED, PIN])
        self.assertEqual(result["items"][0], source[0])
        self.assertEqual(result["items"][1]["metadata"]["name"], BOM["catalog"]["source"])
        self.assertEqual(result["items"][1]["spec"]["image"], PIN)
        self.assertEqual(source[1]["spec"]["image"], EXPECTED)
        self.assertTrue(evidence["immutableRereadVerified"])
        self.assertNotEqual(evidence["sourceCatalog"].split("@")[1], evidence["mirroredCatalog"].split("@")[1])

    def assert_rejected_before_registry(self, documents, message):
        def unexpected(_):
            self.fail("registry accessed before structural rejection")
        with self.assertRaisesRegex(ValueError, message):
            MODULE.normalize(documents, BOM, ENDPOINT, unexpected)

    def test_unrelated_catalog_not_renamed(self):
        documents = docs()
        documents[1]["spec"]["image"] = ENDPOINT + "/redhat/other-index:sha256-" + "1" * 64
        self.assert_rejected_before_registry(documents, "expected digest-derived mirror tag")

    def test_wrong_registry_not_accepted(self):
        documents = docs()
        documents[1]["spec"]["image"] = EXPECTED.replace(ENDPOINT, "other.example:8443")
        self.assert_rejected_before_registry(documents, "expected digest-derived mirror tag")

    def test_ambiguous_catalogs_rejected(self):
        documents = docs()
        documents.append(copy.deepcopy(documents[1]))
        self.assert_rejected_before_registry(documents, "exactly one")

    def test_missing_catalog_rejected(self):
        self.assert_rejected_before_registry(docs()[:1], "exactly one")

    def test_unexpected_resource_rejected(self):
        documents = docs() + [{"kind": "Secret", "data": {}}]
        self.assert_rejected_before_registry(documents, "unexpected generated resource")

    def test_wrong_namespace_rejected(self):
        documents = docs()
        documents[1]["metadata"]["namespace"] = "default"
        self.assert_rejected_before_registry(documents, "namespace")

    def test_immutable_reread_must_match(self):
        def inspect(ref):
            result = info(ref)
            if "@" in ref:
                result["digest"] = "sha256:" + "3" * 64
            return result
        with self.assertRaisesRegex(ValueError, "immutable reread differs"):
            MODULE.normalize(docs(), BOM, ENDPOINT, inspect)

    def test_unresolved_bom_rejected(self):
        bom = copy.deepcopy(BOM)
        bom["catalog"]["resolution"] = "unresolved"
        with self.assertRaisesRegex(ValueError, "verified immutable BOM"):
            MODULE.normalize(docs(), bom, ENDPOINT, info)

    def test_oc_metadata_integrity_architecture_and_catalog_checks(self):
        cases = []
        wrong_digest = info(EXPECTED)
        wrong_digest["contentDigest"] = "sha256:" + "4" * 64
        cases.append(wrong_digest)
        wrong_arch = info(EXPECTED)
        wrong_arch["config"]["architecture"] = "arm64"
        cases.append(wrong_arch)
        not_catalog = info(EXPECTED)
        not_catalog["config"]["config"]["Labels"] = {}
        cases.append(not_catalog)
        for document in cases:
            with self.subTest(document=document), patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(document), "")):
                with self.assertRaises(ValueError):
                    MODULE.inspect_image("oc", EXPECTED)

    def test_oc_preserves_argument_boundaries_and_verification(self):
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(info(EXPECTED)), "")) as command:
            MODULE.inspect_image("oc", EXPECTED, "/outside/path with spaces/auth.json", "/outside/ca file.pem")
        args = command.call_args.args[0]
        self.assertIn("/outside/path with spaces/auth.json", args)
        self.assertIn("/outside/ca file.pem", args)
        self.assertNotIn("--insecure", args)
        self.assertNotIn("--skip-verification", args)

    def test_cli_failure_leaves_existing_output_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "bom.json").write_text(json.dumps(BOM))
            (directory / "resources.json").write_text(json.dumps(docs() + [docs()[1]]))
            (directory / "output.json").write_text("existing reviewed output\n")
            command = ["python3", str(SCRIPT), "--manifest", str(directory / "bom.json"),
                       "--input-json", str(directory / "resources.json"), "--mirror-endpoint", ENDPOINT,
                       "--output", str(directory / "output.json"), "--evidence", str(directory / "evidence.json"),
                       "--oc", str(directory / "must-not-run")]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one", result.stderr)
            self.assertEqual((directory / "output.json").read_text(), "existing reviewed output\n")
            self.assertFalse((directory / "evidence.json").exists())


if __name__ == "__main__":
    unittest.main()
