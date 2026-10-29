#!/usr/bin/env python3
"""Build the reviewed SNP reference set from Veritas output and the collected VCEKs.

Veritas calculates the launch measurement but not the platform's firmware levels.
The Trustee CPU policy checks four of them (snp_bootloader, snp_microcode,
snp_snp_svn, snp_tee_svn) against the guest report's reported TCB. Each collected
VCEK was requested for exactly that TCB, so its URL carries the four values
(blSPL, ucodeSPL, snpSPL, teeSPL). This script adds them, drops records the CPU
policy does not use, and prints every record for review. Nothing is published.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import trustee_config  # noqa: E402
import vcek_bundle  # noqa: E402

# Reference name -> VCEK URL parameter (AMD KDS VCEK request format).
TCB = {"snp_bootloader": "blSPL", "snp_tee_svn": "teeSPL", "snp_snp_svn": "snpSPL", "snp_microcode": "ucodeSPL"}
LAUNCH = "snp_launch_measurement"


def tcb_levels(directory):
    """The four TCB values from a VCEK whose certificate matches its URL request."""
    vcek_bundle.current(directory)  # Refuses a URL that changed after the download.
    url = (directory / "vcek.url").read_text().strip()
    query = parse_qs(urlsplit(url).query)
    levels = {}
    for name, param in TCB.items():
        values = query.get(param, [])
        if len(values) != 1 or not values[0].isdigit():
            raise ValueError(f"{directory.name[:16]}: VCEK URL has no single {param} value")
        levels[name] = int(values[0])
    return levels


def review(generated, bundle, hwids, drop):
    document = trustee_config.load_document(generated)
    encoded = trustee_config.rvps_values(document)
    records = {name: json.loads(base64.b64decode(value)) for name, value in encoded.items()}
    if LAUNCH not in records:
        raise ValueError(f"Veritas output has no {LAUNCH} record")
    for name in drop:
        if name not in records:
            raise ValueError(f"no {name} record to drop; check the Veritas output")
        del records[name]
    if not hwids:
        raise ValueError("set HWIDS to the approved workers' chip IDs (trustee.md)")
    collected = {name: set() for name in TCB}
    for hwid in hwids:
        for name, level in tcb_levels(bundle / hwid).items():
            collected[name].add(level)
    template = records[LAUNCH]
    sources = {}
    for name, levels in collected.items():
        value = sorted(levels)
        if name in records and records[name].get("value") != value:
            raise ValueError(f"{name} in the Veritas output ({records[name].get('value')}) differs from the VCEK TCB ({value})")
        record = {"name": name, "expiration": template["expiration"], "value": value}
        if "version" in template:
            record = {"version": template["version"], **record}
        records[name] = record
        sources[name] = f"VCEK URL {TCB[name]}"
    # Re-validate the complete set exactly as configure will.
    values = trustee_config.rvps_values(list(records.values()))
    metadata = document.get("metadata", {}) if isinstance(document, dict) else {}
    configmap = {"apiVersion": "v1", "kind": "ConfigMap",
                 "metadata": {"name": trustee_config.name(metadata.get("name", "trustee-config-rvps-reference-values")),
                              "namespace": trustee_config.name(metadata.get("namespace", "trustee-operator-system"))},
                 "data": {"reference_value": json.dumps(values, sort_keys=True)}}
    rows = [(name, json.dumps(records[name]["value"]), records[name]["expiration"], sources.get(name, "Veritas"))
            for name in sorted(records)]
    return configmap, rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("generated", type=Path, help="Veritas output from gen-rvps-veritas.sh")
    parser.add_argument("out", type=Path, help="reviewed reference set for apply-trustee.sh configure")
    state = Path(os.environ.get("COCO_STATE_DIR") or Path.home() / ".local/state/openshift-confidential-containers")
    parser.add_argument("--vcek-bundle", type=Path, default=Path(os.environ.get("VCEK_BUNDLE") or state / "vcek-bundle"))
    parser.add_argument("--hwids", default=os.environ.get("HWIDS", ""), help="approved chip IDs (default: HWIDS)")
    parser.add_argument("--drop", action="append", default=[], metavar="NAME",
                        help="remove a record the CPU policy does not use (repeatable)")
    args = parser.parse_args()
    try:
        configmap, rows = review(args.generated, args.vcek_bundle, args.hwids.replace(",", " ").lower().split(), args.drop)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        old = os.umask(0o077)
        try:
            args.out.write_text(json.dumps(configmap, indent=2) + "\n")
        finally:
            os.umask(old)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"ERROR: references: {exc}", file=sys.stderr)
        return 2
    width = max(len(row[0]) for row in rows)
    for name, value, expiration, source in rows:
        print(f"{name:<{width}}  {value}  (expires {expiration}; {source})")
    if os.environ.get("SHOW_NEXT") == "0":  # make trustee-lab asks for the approval itself.
        print(f"Wrote {args.out}.")
    else:
        print(f"Wrote {args.out}. Review every value above before Trustee configure; generating it does not approve it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
