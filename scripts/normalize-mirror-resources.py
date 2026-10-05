#!/usr/bin/env python3
"""Validate the one selected mirrored catalog, pin its image, and emit cluster resources.

The filtered mirror catalog has its own digest: it is not the upstream index digest.
Only registry metadata is read. No Kubernetes request is made by this command.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
NAME = re.compile(r"[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?")


def expected_image(bom, endpoint):
    catalog = bom["catalog"]
    digest = catalog.get("digest", "")
    if catalog.get("resolution") != "verified" or not DIGEST.fullmatch(digest):
        raise ValueError("catalog must have a verified immutable BOM identity")
    if not catalog["ref"].endswith("@" + digest):
        raise ValueError("catalog reference and digest disagree")
    if not NAME.fullmatch(catalog["source"]):
        raise ValueError("invalid BOM CatalogSource name")
    if not endpoint or any(c.isspace() for c in endpoint) or "://" in endpoint or endpoint.endswith("/") or "@" in endpoint:
        raise ValueError("mirror endpoint must be an explicit registry[/namespace]")
    source_repository = catalog["ref"].split("@", 1)[0]
    if "/" not in source_repository:
        raise ValueError("catalog must name an explicit source registry")
    repository = endpoint + "/" + source_repository.split("/", 1)[1]
    return repository + ":" + digest.replace(":", "-", 1)


def inspect_image(oc, ref, registry_config=None, certificate_authority=None):
    args = [oc, "image", "info", "--filter-by-os=linux/amd64", "--output=json"]
    if registry_config:
        args += ["--registry-config", registry_config]
    if certificate_authority:
        args += ["--certificate-authority", certificate_authority]
    # Integrity and TLS verification remain enabled; never use --insecure or --skip-verification.
    result = subprocess.run(args + [ref], capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError("could not verify mirrored catalog metadata: " + result.stderr.strip())
    info = json.loads(result.stdout)
    digest = info.get("digest", "")
    if info.get("name") != ref or not DIGEST.fullmatch(digest) or info.get("contentDigest") != digest:
        raise ValueError("registry image identity or content digest does not match inspection")
    config = info.get("config", {})
    if config.get("os") != "linux" or config.get("architecture") != "amd64":
        raise ValueError("mirrored catalog is not Linux/AMD64")
    if not config.get("config", {}).get("Labels", {}).get("operators.operatorframework.io.index.configs.v1"):
        raise ValueError("mirrored image lacks file-based catalog metadata")
    return info


def normalize(documents, bom, endpoint, inspect):
    expected = expected_image(bom, endpoint)
    repository = expected.rsplit(":", 1)[0]
    if not documents or any(not isinstance(d, dict) for d in documents):
        raise ValueError("expected generated Kubernetes resource objects")
    allowed = {"CatalogSource", "ImageDigestMirrorSet", "ImageTagMirrorSet"}
    if any(d.get("kind") not in allowed for d in documents):
        raise ValueError("unexpected generated resource kind; review before applying")
    catalogs = [d for d in documents if d.get("kind") == "CatalogSource"]
    if len(catalogs) != 1:
        raise ValueError("expected exactly one CatalogSource; unrelated or ambiguous catalogs are rejected")
    catalog = catalogs[0]
    metadata, spec = catalog.get("metadata", {}), catalog.get("spec", {})
    if catalog.get("apiVersion") != "operators.coreos.com/v1alpha1" or metadata.get("namespace") != "openshift-marketplace" or spec.get("sourceType") != "grpc":
        raise ValueError("unexpected CatalogSource API, namespace or source type")
    if spec.get("image") != expected:
        raise ValueError("CatalogSource image is not the expected digest-derived mirror tag: " + expected)
    # Complete all structural checks before registry access or writing output.
    first = inspect(expected)
    pin = repository + "@" + first["digest"]
    second = inspect(pin)
    if first["digest"] != second["digest"] or first["contentDigest"] != second["contentDigest"]:
        raise ValueError("mirrored catalog immutable reread differs from its selected tag")
    result = copy.deepcopy(documents)
    selected = next(d for d in result if d["kind"] == "CatalogSource")
    selected["metadata"]["name"] = bom["catalog"]["source"]
    selected["spec"]["image"] = pin
    evidence = {
        "sourceCatalog": bom["catalog"]["ref"], "expectedMirrorTag": expected,
        "mirroredCatalog": pin, "selectedPlatform": "linux/amd64",
        "sourceName": metadata.get("name"), "normalizedName": bom["catalog"]["source"],
        "immutableRereadVerified": True,
        "note": "Filtered catalog content has its own digest; upstream and mirror digests need not match.",
    }
    return {"apiVersion": "v1", "kind": "List", "items": result}, evidence


def atomic_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(document, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--resources-dir", type=Path)
    inputs.add_argument("--input-json", type=Path)
    parser.add_argument("--mirror-endpoint", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--oc", default="oc")
    parser.add_argument("--registry-config")
    parser.add_argument("--certificate-authority")
    args = parser.parse_args()
    try:
        if args.resources_dir:
            import yaml
            documents = []
            for path in sorted(args.resources_dir.glob("*.yaml")):
                documents.extend(d for d in yaml.safe_load_all(path.read_text()) if d)
        else:
            documents = json.loads(args.input_json.read_text())
        bom = json.loads(args.manifest.read_text())
        output, evidence = normalize(documents, bom, args.mirror_endpoint, lambda ref: inspect_image(args.oc, ref, args.registry_config, args.certificate_authority))
        atomic_json(args.evidence, evidence)
        atomic_json(args.output, output)
        print("Verified mirrored catalog and normalized CatalogSource: " + evidence["normalizedName"])
        return 0
    except (OSError, ValueError, KeyError, TypeError, ImportError) as exc:
        print("ERROR: mirror resource normalization: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
