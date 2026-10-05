#!/usr/bin/env python3
"""Offline regression tests for catalog naming, origin selection and immutable identity."""
import copy
import base64
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
FILTERED_DIGEST = "sha256:" + "3" * 64
PAYLOAD_DIGEST = "sha256:" + "4" * 64
ENDPOINT = "mirror.example:8443"
BOM = {"catalog": {"ref": "registry.redhat.io/redhat/redhat-operator-index@" + SOURCE_DIGEST,
                   "digest": SOURCE_DIGEST, "resolution": "verified", "source": "cs-redhat-operator-index-v4-20"}}
EXPECTED = ENDPOINT + "/redhat/redhat-operator-index:sha256-" + "1" * 64
PIN = ENDPOINT + "/redhat/redhat-operator-index@" + MIRROR_DIGEST
FILTERED_TAG = ENDPOINT + "/redhat/redhat-operator-index:sha256-" + "3" * 64


def docs():
    return [
        {"apiVersion": "config.openshift.io/v1", "kind": "ImageDigestMirrorSet", "metadata": {"name": "idms"}, "spec": {"imageDigestMirrors": []}},
        {"apiVersion": "operators.coreos.com/v1alpha1", "kind": "CatalogSource", "metadata": {"name": "cs-redhat-operator-index-sha256-111", "namespace": "openshift-marketplace"}, "spec": {"sourceType": "grpc", "image": EXPECTED}},
    ]


def info(ref):
    return {"name": ref, "digest": MIRROR_DIGEST, "contentDigest": MIRROR_DIGEST,
            "config": {"os": "linux", "architecture": "amd64", "config": {"Labels": {"operators.operatorframework.io.index.configs.v1": "/configs"}}}}


def signature():
    return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {
        "name": "mirrored-release-signatures", "namespace": "openshift-config-managed",
        "labels": {"release.openshift.io/verification-signatures": ""}},
        "binaryData": {PAYLOAD_DIGEST.replace(":", "-") + "-1": base64.b64encode(b"signature bytes, CVO verifies trust").decode()}}


def filtered_bom():
    bom = copy.deepcopy(BOM)
    bom["platform"] = {"releaseImage": "quay.io/openshift-release-dev/ocp-release@" + PAYLOAD_DIGEST}
    bom["operators"] = {"osc": {"package": "sandboxed-containers-operator", "channel": "stable",
        "startingCSV": "sandboxed-containers-operator.v1.13.1", "version": "1.13.1",
        "bundleImage": "registry.redhat.io/osc/bundle@" + SOURCE_DIGEST, "resolution": "verified"}}
    return bom


def filtered_documents():
    result = docs()
    result[1]["spec"]["image"] = FILTERED_TAG
    result.append({"apiVersion": "olm.operatorframework.io/v1", "kind": "ClusterCatalog",
        "metadata": {"name": "cc-redhat-operator-index-sha256-33333"},
        "spec": {"priority": 0, "source": {"type": "Image", "image": {"ref": FILTERED_TAG}}}})
    result.append(signature())
    return result


def write_filter(working, filter_name="selected", digest=FILTERED_DIGEST):
    root = working / "operator-catalogs/redhat-operator-index" / SOURCE_DIGEST.split(":")[1] / "filtered-catalogs" / filter_name
    root.mkdir(parents=True)
    (root / "digest").write_text(digest.split(":")[1])
    operator = filtered_bom()["operators"]["osc"]
    fbc = [{"schema": "olm.package", "name": operator["package"], "defaultChannel": "stable"},
           {"schema": "olm.channel", "name": "stable", "package": operator["package"], "entries": [{"name": operator["startingCSV"]}]},
           {"schema": "olm.bundle", "name": operator["startingCSV"], "package": operator["package"], "image": operator["bundleImage"],
            "properties": [{"type": "olm.package", "value": {"packageName": operator["package"], "version": operator["version"]}}]}]
    config = root / "catalog-config" / operator["package"]
    config.mkdir(parents=True)
    (config / "catalog.json").write_text("\n".join(json.dumps(d) for d in fbc))
    return root


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

    def test_actual_generated_kinds_preserve_signature_and_omit_matching_olmv1_catalog(self):
        documents = filtered_documents()
        calls = []
        def inspect(ref):
            calls.append(ref)
            result = info(ref)
            if ref == FILTERED_TAG:
                result["listDigest"] = FILTERED_DIGEST
            return result
        output, evidence = MODULE.normalize(documents, filtered_bom(), ENDPOINT, inspect, FILTERED_DIGEST)
        self.assertEqual(calls, [FILTERED_TAG, PIN])
        self.assertEqual([d["kind"] for d in output["items"]], ["ImageDigestMirrorSet", "CatalogSource", "ConfigMap"])
        self.assertEqual(output["items"][-1], documents[-1])
        self.assertEqual(output["items"][1]["spec"]["image"], PIN)
        self.assertEqual(evidence["mirroredCatalogIndexDigest"], FILTERED_DIGEST)
        self.assertEqual(len(evidence["retainedReleaseSignatureSha256"]), 1)
        self.assertEqual(evidence["omittedClusterCatalogs"], [documents[2]["metadata"]["name"]])

    def test_unrelated_or_ambiguous_olmv1_catalog_rejected_before_registry(self):
        for change in ("image", "api", "namespace", "duplicate"):
            documents = filtered_documents()
            if change == "image": documents[2]["spec"]["source"]["image"]["ref"] = "other.example/index:latest"
            if change == "api": documents[2]["apiVersion"] = "other/v1"
            if change == "namespace": documents[2]["metadata"]["namespace"] = "default"
            if change == "duplicate": documents.append(copy.deepcopy(documents[2]))
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "ClusterCatalog"):
                MODULE.normalize(documents, filtered_bom(), ENDPOINT, lambda _: self.fail("registry accessed"), FILTERED_DIGEST)

    def test_unrelated_or_invalid_signature_configmap_rejected_before_registry(self):
        for change in ("name", "namespace", "label", "payload", "base64", "data", "empty", "conflict", "metadata-conflict"):
            documents = filtered_documents()
            cm = documents[-1]
            if change == "name": cm["metadata"]["name"] = "unrelated"
            if change == "namespace": cm["metadata"]["namespace"] = "default"
            if change == "label": cm["metadata"]["labels"] = {}
            if change == "payload": cm["binaryData"] = {"sha256-" + "9" * 64 + "-1": "YWJj"}
            if change == "base64": cm["binaryData"][next(iter(cm["binaryData"]))] = "invalid base64!"
            if change == "data": cm["data"] = {"extra": "unrelated"}
            if change == "empty": cm["binaryData"] = {}
            if change == "conflict":
                documents.append(copy.deepcopy(cm))
                documents[-1]["binaryData"][next(iter(cm["binaryData"]))] = "ZGlmZmVyZW50"
            if change == "metadata-conflict":
                documents.append(copy.deepcopy(cm))
                documents[-1]["metadata"]["annotations"] = {"unexpected": "different"}
            with self.subTest(change=change), self.assertRaises(ValueError):
                MODULE.normalize(documents, filtered_bom(), ENDPOINT, lambda _: self.fail("registry accessed"), FILTERED_DIGEST)

    def test_filtered_tag_must_resolve_to_recorded_index_or_single_manifest_digest(self):
        with self.assertRaisesRegex(ValueError, "workspace filtered catalog digest"):
            MODULE.normalize(filtered_documents(), filtered_bom(), ENDPOINT, info, FILTERED_DIGEST)
        def inspect(ref):
            result = info(ref)
            result["digest"] = result["contentDigest"] = FILTERED_DIGEST
            return result
        output, _ = MODULE.normalize(filtered_documents(), filtered_bom(), ENDPOINT, inspect, FILTERED_DIGEST)
        self.assertEqual(output["items"][1]["spec"]["image"], ENDPOINT + "/redhat/redhat-operator-index@" + FILTERED_DIGEST)

    def test_workspace_selects_generated_filter_and_preserves_older_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            working = Path(directory)
            write_filter(working)
            old = write_filter(working, "old", "sha256:" + "9" * 64)
            digest, evidence = MODULE.filtered_catalog_identity(working, filtered_bom(), filtered_documents())
            self.assertEqual(digest, FILTERED_DIGEST)
            self.assertTrue(evidence["inventoryMatchesBOM"])
            self.assertTrue(old.exists())

    def test_workspace_wrong_origin_missing_or_ambiguous_record_rejected(self):
        for change in ("origin", "missing", "duplicate"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                working = Path(directory)
                root = write_filter(working)
                bom = filtered_bom()
                if change == "origin":
                    bom["catalog"]["digest"] = "sha256:" + "9" * 64
                    bom["catalog"]["ref"] = "registry.redhat.io/redhat/redhat-operator-index@" + bom["catalog"]["digest"]
                if change == "missing": (root / "digest").unlink()
                if change == "duplicate": write_filter(working, "duplicate")
                with self.assertRaisesRegex(ValueError, "matching filtered catalog digest"):
                    MODULE.filtered_catalog_identity(working, bom, filtered_documents())

    def test_filtered_inventory_must_match_exact_bom_version_bundle_and_channel(self):
        for key in ("version", "bundleImage", "startingCSV", "channel", "package"):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                working = Path(directory)
                write_filter(working)
                bom = filtered_bom()
                bom["operators"]["osc"][key] = "unrelated"
                with self.assertRaisesRegex(ValueError, "differs from BOM"):
                    MODULE.filtered_catalog_identity(working, bom, filtered_documents())

    def test_resources_directory_keeps_json_signatures_and_infers_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            working = root / "working-dir"
            write_filter(working)
            resources = working / "cluster-resources"
            resources.mkdir()
            for index, document in enumerate(filtered_documents()):
                suffix = ".json" if document["kind"] == "ConfigMap" else ".yaml"
                (resources / (str(index) + suffix)).write_text(json.dumps(document))
            # oc-mirror workspaces may retain the same generated ConfigMap in
            # both JSON and YAML. Preserve one exact copy, never silently merge.
            (resources / "signature-copy.yaml").write_text(json.dumps(signature()))
            (root / "bom.json").write_text(json.dumps(filtered_bom()))
            argv = [str(SCRIPT), "--manifest", str(root / "bom.json"),
                    "--resources-dir", str(resources), "--mirror-endpoint", ENDPOINT,
                    "--output", str(root / "output.json"), "--evidence", str(root / "evidence.json")]
            def inspect(_, ref, *args):
                result = info(ref)
                if ref == FILTERED_TAG: result["listDigest"] = FILTERED_DIGEST
                return result
            with patch.object(MODULE.sys, "argv", argv), patch.object(MODULE, "inspect_image", side_effect=inspect):
                self.assertEqual(MODULE.main(), 0)
            output = json.loads((root / "output.json").read_text())
            self.assertEqual(output["items"][-1], signature())
            self.assertEqual(sum(d["kind"] == "ConfigMap" for d in output["items"]), 1)
            evidence = json.loads((root / "evidence.json").read_text())
            self.assertTrue(evidence["filteredCatalogWorkspace"]["inventoryMatchesBOM"])
            self.assertEqual(evidence["identicalSignatureCopiesOmitted"], 1)

    def test_input_json_with_explicit_workspace_preserves_signatures_and_pins_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            working = root / "working-dir"
            write_filter(working)
            documents = filtered_documents() + [copy.deepcopy(signature())]
            (root / "bom.json").write_text(json.dumps(filtered_bom()))
            (root / "resources.json").write_text(json.dumps(documents))
            argv = [str(SCRIPT), "--manifest", str(root / "bom.json"),
                    "--input-json", str(root / "resources.json"), "--working-dir", str(working),
                    "--mirror-endpoint", ENDPOINT, "--output", str(root / "output.json"),
                    "--evidence", str(root / "evidence.json")]
            def inspect(_, ref, *args):
                result = info(ref)
                if ref == FILTERED_TAG: result["listDigest"] = FILTERED_DIGEST
                return result
            with patch.object(MODULE.sys, "argv", argv), patch.object(MODULE, "inspect_image", side_effect=inspect):
                self.assertEqual(MODULE.main(), 0)
            output = json.loads((root / "output.json").read_text())
            self.assertEqual([d["kind"] for d in output["items"]], ["ImageDigestMirrorSet", "CatalogSource", "ConfigMap"])
            self.assertEqual(output["items"][1]["spec"]["image"], PIN)
            self.assertEqual(output["items"][-1], signature())
            evidence = json.loads((root / "evidence.json").read_text())
            self.assertTrue(evidence["filteredCatalogWorkspace"]["inventoryMatchesBOM"])
            self.assertEqual(evidence["identicalSignatureCopiesOmitted"], 1)

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
                       "--working-dir", str(directory / "working-dir"),
                       "--output", str(directory / "output.json"), "--evidence", str(directory / "evidence.json"),
                       "--oc", str(directory / "must-not-run")]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one", result.stderr)
            self.assertEqual((directory / "output.json").read_text(), "existing reviewed output\n")
            self.assertFalse((directory / "evidence.json").exists())

    def test_input_json_cannot_skip_filtered_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bom.json").write_text(json.dumps(BOM))
            (root / "resources.json").write_text(json.dumps(docs()))
            result = subprocess.run(["python3", str(SCRIPT), "--manifest", str(root / "bom.json"),
                "--input-json", str(root / "resources.json"), "--mirror-endpoint", ENDPOINT,
                "--output", str(root / "output.json"), "--evidence", str(root / "evidence.json"),
                "--oc", str(root / "must-not-run")], capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--working-dir is required", result.stderr)
            self.assertFalse((root / "output.json").exists())


if __name__ == "__main__":
    unittest.main()
