#!/usr/bin/env python3
"""Offline BOM/manifest agreement and a fail-closed deployment-readiness gate.

Resolution records are reviewed input, not proof of registry availability. This
command performs no network, credential, or cluster access. Resolve candidates
from catalog/registry evidence, then rerun before using a changed artifact set.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
IMAGE = re.compile(r"^[^\s]+@sha256:[0-9a-f]{64}$")


def value(document, key):
    for part in key.split("."):
        document = document[part]
    return document


def version(text):
    if not isinstance(text, str) or not re.fullmatch(r"\d+\.\d+\.\d+", text):
        raise ValueError(f"invalid release version: {text!r}")
    return tuple(map(int, text.split(".")))


def validate(bom, root, tee="snp", require_resolved=False, environ=None):
    import yaml  # PyYAML is required for checks; --get needs only Python stdlib.
    errors = []
    env = os.environ if environ is None else environ
    def check(condition, message):
        if not condition:
            errors.append(message)
    def read_yaml(path):
        return [d for d in yaml.safe_load_all((root / path).read_text()) if d]
    check(bom.get("schemaVersion") == 1, "unsupported BOM schemaVersion")
    p = bom["platform"]
    minor = ".".join(p["version"].split(".")[:2])
    floor = bom["compatibility"]["cpuMinimums"].get(minor)
    check(floor is not None and version(p["version"]) >= version(floor), "OCP version is below or outside the documented CPU compatibility matrix")
    check(p["channel"] == f"stable-{minor}", "platform channel/version mismatch")
    check(bool(IMAGE.fullmatch(p["releaseImage"])), "platform.releaseImage must be immutable")
    check(bom["compatibility"].get("gpus") is False, "this BOM is CPU-only")
    if tee != "snp" or tee not in bom["profiles"]:
        raise ValueError("this deployment supports the AMD SNP profile only")
    bindings = {"OCP_VERSION":"platform.version", "OCP_RELEASE_IMAGE":"platform.releaseImage", "OSC_VERSION":"operators.osc.version", "TRUSTEE_VERSION":"operators.trustee.version", "CATALOGSOURCE":"catalog.source", "TOOLS_IMG":"images.cocoTools.ref"}
    for name, key in bindings.items():
        check(not env.get(name) or env[name] == value(bom, key), f"{name} override disagrees with BOM {key}; select/update a matching BOM")
    image_set_path = env.get("IMAGESET_CONFIG") or bom["profiles"][tee]["imageSet"]
    image_set = read_yaml(image_set_path)[0]["mirror"]
    channels = image_set["platform"]["channels"]
    check(len(channels) == 1 and channels[0]["name"] == p["channel"] and channels[0]["minVersion"] == p["version"] and channels[0]["maxVersion"] == p["version"], "ImageSet platform pin differs from BOM")
    packages = {pkg["name"]:pkg for cat in image_set["operators"] for pkg in cat["packages"]}
    check(any(cat["catalog"] == bom["catalog"]["ref"] for cat in image_set["operators"]), "ImageSet catalog differs from BOM")
    subscription_docs = read_yaml("gitops/base/operators/subscriptions.yaml") + read_yaml("gitops/base/gatekeeper/operator.yaml")
    subscriptions = {d["spec"]["name"]:d for d in subscription_docs if d.get("kind") == "Subscription"}
    for key, op in bom["operators"].items():
        package = packages.get(op["package"])
        if package is None:
            errors.append(f"ImageSet missing package operators.{key}: {op['package']}")
            continue
        package_channels = package.get("channels", [])
        check(len(package_channels) == 1, f"ImageSet {key} requires exactly one channel")
        channel = package_channels[0] if package_channels else {}
        check(channel.get("name") == op["channel"], f"ImageSet {key} channel differs from BOM")
        if op.get("version"):
            check(channel.get("minVersion") == op["version"] and channel.get("maxVersion") == op["version"], f"ImageSet {key} pin differs from BOM")
        elif channel.get("minVersion") or channel.get("maxVersion"):
            errors.append(f"ImageSet {key} has version pins missing from BOM")
        sub = subscriptions.get(op["package"], {}).get("spec", {})
        check(sub.get("channel") == op["channel"], f"Subscription {key} channel differs from BOM")
        # Supporting startingCSVs are injected from the resolved BOM at render time.
        # An explicit static pin, if present, must agree too.
        if key in ("osc", "trustee") or sub.get("startingCSV"):
            check(sub.get("startingCSV") == op.get("startingCSV"), f"Subscription {key} startingCSV differs from BOM")
    for sub in subscriptions.values():
        check(sub["spec"]["source"] == bom["catalog"]["source"], "Subscription catalog source differs from BOM")
        check(sub["spec"]["installPlanApproval"] == "Manual", "target Subscriptions must require explicit InstallPlan approval")
    actual_images = {i["name"] for i in image_set.get("additionalImages", [])}
    for key, image in bom["images"].items():
        check(image["ref"] in actual_images, f"ImageSet missing images.{key}")
    profile = bom["profiles"][tee]
    check(profile["runtimeHandler"] == f"kata-{tee}", "profile runtime handler/TEE mismatch")
    if require_resolved:
        for label, item in [("platform", p), ("catalog", bom["catalog"])]:
            check(item.get("resolution") == "verified", f"unresolved {label}: {item.get('reason', 'missing verification')}")
        check(bool(DIGEST.fullmatch(bom["catalog"].get("digest") or "")), "catalog digest has not been resolved")
        check(bom["catalog"]["ref"].endswith("@" + (bom["catalog"].get("digest") or "")), "resolved catalog reference must use its verified digest")
        for key, op in bom["operators"].items():
            check(all(op.get(field) for field in ("package", "version", "channel", "startingCSV")), f"unresolved operators.{key}: package/version/channel/startingCSV required")
            check(op.get("resolution") == "verified" and bool(IMAGE.fullmatch(op.get("bundleImage") or "")) and bool(op.get("relatedImages")) and all(IMAGE.fullmatch(i) for i in op.get("relatedImages", [])), f"unresolved operators.{key}: verified bundle and immutable relatedImages required")
        for key, image in bom["images"].items():
            check(image.get("resolution") == "verified" and bool(IMAGE.fullmatch(image["ref"])), f"unresolved images.{key}: {image.get('reason', 'immutable verified image required')}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(os.environ.get("RELEASE_MANIFEST", ROOT / "install/release-manifest.json")))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--tee", choices=("snp",), default=os.environ.get("TEE", "snp"))
    parser.add_argument("--get", metavar="DOTTED_KEY")
    parser.add_argument("--require-resolved", action="store_true")
    args = parser.parse_args()
    try:
        bom = json.loads(args.manifest.read_text())
        if args.get:
            result = value(bom, args.get)
            if result is None:
                raise ValueError(f"unresolved value: {args.get}")
            print(json.dumps(result) if isinstance(result, (dict, list, bool)) else result)
            return 0
        errors = validate(bom, args.root, args.tee, args.require_resolved)
    except (OSError, ValueError, KeyError, TypeError, ImportError) as exc:
        print(f"ERROR: release validation: {exc}", file=sys.stderr)
        return 2
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    print("Release manifests agree" + ("; artifact identities resolved" if args.require_resolved else "; deployment readiness NOT checked (use --require-resolved)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
