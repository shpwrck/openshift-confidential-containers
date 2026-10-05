#!/usr/bin/env python3
"""Validate the one selected mirrored catalog, pin its image, and emit cluster resources.

The filtered mirror catalog has its own digest: it is not the upstream index digest.
Only registry metadata is read. No Kubernetes request is made by this command.
"""
import argparse
import base64
import binascii
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
NAME = re.compile(r"[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?")


def expected_image(bom, endpoint, filtered_digest=None):
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
    if filtered_digest is not None and not DIGEST.fullmatch(filtered_digest):
        raise ValueError("invalid filtered catalog digest")
    return repository + ":" + (filtered_digest or digest).replace(":", "-", 1)


def validate_filtered_inventory(config_dir, bom):
    """Require the filtered FBC package/channel/bundle selection from the BOM."""
    operators = list(bom.get("operators", {}).values())
    if not operators or any(op.get("resolution") != "verified" for op in operators):
        raise ValueError("filtered catalog requires verified BOM operator selections")
    objects, hashes = [], {}
    decoder = json.JSONDecoder()
    for path in sorted(config_dir.rglob("*.json")):
        raw = path.read_bytes()
        hashes[str(path.relative_to(config_dir))] = hashlib.sha256(raw).hexdigest()
        remaining = raw.decode().strip()
        while remaining:
            document, end = decoder.raw_decode(remaining)
            if not isinstance(document, dict):
                raise ValueError("filtered catalog must contain FBC resource objects")
            objects.append(document)
            remaining = remaining[end:].lstrip()
    packages = [d for d in objects if d.get("schema") == "olm.package"]
    channels = [d for d in objects if d.get("schema") == "olm.channel"]
    bundles = [d for d in objects if d.get("schema") == "olm.bundle"]
    if (len(objects) != len(packages) + len(channels) + len(bundles)
            or any(len(group) != len(operators) for group in (packages, channels, bundles))):
        raise ValueError("filtered catalog inventory differs from the exact BOM operator selection")
    for operator in operators:
        name, csv, channel = operator["package"], operator["startingCSV"], operator["channel"]
        selected_packages = [p for p in packages if p.get("name") == name and p.get("defaultChannel") == channel]
        selected_channels = [c for c in channels if c.get("package") == name and c.get("name") == channel
                             and [entry.get("name") for entry in c.get("entries", [])] == [csv]]
        selected_bundles = [b for b in bundles if b.get("package") == name and b.get("name") == csv
                            and b.get("image") == operator["bundleImage"]]
        if any(len(group) != 1 for group in (selected_packages, selected_channels, selected_bundles)):
            raise ValueError("filtered catalog package/channel/CSV/bundle differs from BOM: " + name)
        properties = [p.get("value") for p in selected_bundles[0].get("properties", []) if p.get("type") == "olm.package"]
        if properties != [{"packageName": name, "version": operator["version"]}]:
            raise ValueError("filtered catalog bundle version differs from BOM: " + name)
    return hashes


def filtered_catalog_identity(working_dir, bom, documents):
    """Read oc-mirror's source-digest-scoped filtered catalog record.

    oc-mirror release-4.20 operator/common.go uses FilteredCatalogDigest for
    rebuilt catalogs selected by digest. Select the record matching the generated
    CatalogSource and verify its inventory; older cached filters remain usable.
    """
    expected_image(bom, "validation.invalid")
    catalog = bom["catalog"]
    name = catalog["ref"].split("@", 1)[0].rsplit("/", 1)[1]
    root = working_dir / "operator-catalogs" / name / catalog["digest"].split(":", 1)[1]
    records = sorted((root / "filtered-catalogs").glob("*/digest"))
    catalogs = [d for d in documents if isinstance(d, dict) and d.get("kind") == "CatalogSource"]
    if len(catalogs) != 1:
        raise ValueError("expected exactly one CatalogSource")
    tag = catalogs[0].get("spec", {}).get("image", "").rsplit(":", 1)[-1]
    if not re.fullmatch(r"sha256-[0-9a-f]{64}", tag):
        raise ValueError("expected digest-derived mirror tag")
    selected_digest = tag.replace("-", ":", 1)
    records = [r for r in records if r.read_text().strip().removeprefix("sha256:") == selected_digest.split(":", 1)[1]]
    if len(records) != 1:
        raise ValueError("expected exactly one matching filtered catalog digest under the BOM source digest; review missing or ambiguous workspace filters")
    record = records[0]
    raw = record.read_bytes()
    value = raw.decode().strip()
    digest = value if value.startswith("sha256:") else "sha256:" + value
    if not DIGEST.fullmatch(digest):
        raise ValueError("invalid filtered catalog workspace digest")
    hashes = validate_filtered_inventory(record.parent / "catalog-config", bom)
    return digest, {"record": str(record.relative_to(working_dir)),
                    "recordSha256": hashlib.sha256(raw).hexdigest(),
                    "filteredDigest": digest, "inventoryMatchesBOM": True,
                    "filteredConfigSha256": hashes}


def validate_signatures(document, bom):
    metadata = document.get("metadata", {})
    if (document.get("apiVersion") != "v1"
            or metadata.get("name") != "mirrored-release-signatures"
            or metadata.get("namespace") != "openshift-config-managed"
            or metadata.get("labels", {}).get("release.openshift.io/verification-signatures") != ""):
        raise ValueError("unexpected ConfigMap; only the generated release verification signatures are allowed")
    payload = bom.get("platform", {}).get("releaseImage", "").rsplit("@", 1)[-1]
    if not DIGEST.fullmatch(payload):
        raise ValueError("release signatures require an immutable BOM platform payload")
    values = document.get("binaryData", {})
    pattern = re.compile(re.escape(payload.replace(":", "-")) + r"-[1-9][0-9]*")
    if document.get("data") or not isinstance(values, dict) or not values:
        raise ValueError("release signature ConfigMap must contain only nonempty binaryData")
    hashes = {}
    for key, value in values.items():
        if not pattern.fullmatch(key):
            raise ValueError("release signature key does not match the BOM platform payload")
        try:
            decoded = base64.b64decode(value, validate=True)
        except (ValueError, TypeError, binascii.Error) as exc:
            raise ValueError("invalid release signature base64") from exc
        if not decoded:
            raise ValueError("empty release signature")
        hashes[key] = hashlib.sha256(decoded).hexdigest()
    # CVO performs cryptographic verification. Here we retain the exact signature
    # bytes and check their resource identity and selected-payload key, not trust.
    return hashes


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
    if info.get("listDigest") and not DIGEST.fullmatch(info["listDigest"]):
        raise ValueError("invalid registry catalog index digest")
    config = info.get("config", {})
    if config.get("os") != "linux" or config.get("architecture") != "amd64":
        raise ValueError("mirrored catalog is not Linux/AMD64")
    if not config.get("config", {}).get("Labels", {}).get("operators.operatorframework.io.index.configs.v1"):
        raise ValueError("mirrored image lacks file-based catalog metadata")
    return info


def normalize(documents, bom, endpoint, inspect, filtered_digest=None):
    expected = expected_image(bom, endpoint, filtered_digest)
    repository = expected.rsplit(":", 1)[0]
    if not documents or any(not isinstance(d, dict) for d in documents):
        raise ValueError("expected generated Kubernetes resource objects")
    allowed = {"CatalogSource", "ImageDigestMirrorSet", "ImageTagMirrorSet", "ClusterCatalog", "ConfigMap"}
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
    cluster_catalogs = [d for d in documents if d.get("kind") == "ClusterCatalog"]
    if len(cluster_catalogs) > 1:
        raise ValueError("ambiguous ClusterCatalog resources")
    for other in cluster_catalogs:
        source = other.get("spec", {}).get("source", {})
        if (other.get("apiVersion") != "olm.operatorframework.io/v1"
                or other.get("metadata", {}).get("namespace")
                or source.get("type") != "Image" or source.get("image", {}).get("ref") != expected):
            raise ValueError("unrelated or invalid ClusterCatalog; expected the same mirrored catalog image")
    signatures = [d for d in documents if d.get("kind") == "ConfigMap"]
    # Some runs retain both JSON and a YAML conversion of this generated object.
    # Accept only semantically identical copies; conflicting data or metadata is
    # ambiguous. No other kind is deduplicated by this helper.
    if signatures and any(d != signatures[0] for d in signatures[1:]):
        raise ValueError("conflicting release signature ConfigMaps")
    signature_hashes = validate_signatures(signatures[0], bom) if signatures else {}
    for document in documents:
        if document["kind"] in {"ImageDigestMirrorSet", "ImageTagMirrorSet"}:
            if document.get("apiVersion") != "config.openshift.io/v1" or document.get("metadata", {}).get("namespace"):
                raise ValueError("unexpected mirror-set API or namespace")
    # Complete all structural checks before registry access or writing output.
    first = inspect(expected)
    if filtered_digest and (first.get("listDigest") or first["digest"]) != filtered_digest:
        raise ValueError("registry catalog digest differs from the workspace filtered catalog digest")
    pin = repository + "@" + first["digest"]
    second = inspect(pin)
    if first["digest"] != second["digest"] or first["contentDigest"] != second["contentDigest"]:
        raise ValueError("mirrored catalog immutable reread differs from its selected tag")
    # This repository installs OLM v0 Subscriptions. Do not activate an extra
    # OLM v1 catalog; omit it only after validating its identity above.
    result = []
    signature_kept = False
    for document in documents:
        if document["kind"] == "ClusterCatalog":
            continue
        if document["kind"] == "ConfigMap":
            if signature_kept:
                continue
            signature_kept = True
        result.append(copy.deepcopy(document))
    selected = next(d for d in result if d["kind"] == "CatalogSource")
    selected["metadata"]["name"] = bom["catalog"]["source"]
    selected["spec"]["image"] = pin
    evidence = {
        "sourceCatalog": bom["catalog"]["ref"], "expectedMirrorTag": expected,
        "mirroredCatalog": pin, "selectedPlatform": "linux/amd64",
        "mirroredCatalogIndexDigest": first.get("listDigest"),
        "sourceName": metadata.get("name"), "normalizedName": bom["catalog"]["source"],
        "immutableRereadVerified": True,
        "omittedClusterCatalogs": [d.get("metadata", {}).get("name") for d in cluster_catalogs],
        "retainedReleaseSignatureSha256": signature_hashes,
        "identicalSignatureCopiesOmitted": max(0, len(signatures) - 1),
        "releaseSignatureCryptographicVerification": "deferred to OpenShift CVO",
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
    parser.add_argument("--working-dir", type=Path,
                        help="oc-mirror working-dir with source-scoped filtered catalog metadata (inferred from --resources-dir)")
    args = parser.parse_args()
    try:
        if args.resources_dir:
            import yaml
            documents = []
            paths = sorted(p for p in args.resources_dir.iterdir() if p.suffix in {".yaml", ".yml", ".json"})
            for path in paths:
                documents.extend(d for d in yaml.safe_load_all(path.read_text()) if d)
        else:
            documents = json.loads(args.input_json.read_text())
        bom = json.loads(args.manifest.read_text())
        working_dir = args.working_dir or (args.resources_dir.parent if args.resources_dir else None)
        if working_dir is None:
            raise ValueError("--working-dir is required with --input-json to verify filtered catalog provenance")
        filtered_digest, provenance = filtered_catalog_identity(working_dir, bom, documents)
        output, evidence = normalize(documents, bom, args.mirror_endpoint, lambda ref: inspect_image(args.oc, ref, args.registry_config, args.certificate_authority), filtered_digest)
        if provenance:
            evidence["filteredCatalogWorkspace"] = provenance
        atomic_json(args.evidence, evidence)
        atomic_json(args.output, output)
        print("Verified mirrored catalog and normalized CatalogSource: " + evidence["normalizedName"])
        return 0
    except (OSError, ValueError, KeyError, TypeError, ImportError) as exc:
        print("ERROR: mirror resource normalization: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
