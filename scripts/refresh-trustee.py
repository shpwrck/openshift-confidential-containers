#!/usr/bin/env python3
"""Refresh the selected Operator-owned Trustee pods and verify serving data."""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from proof_core import Cluster, Incomplete, restart_trustee


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--trustee-name", required=True)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if args.timeout < 30:
        parser.error("timeout must allow at least 30 seconds")
    try:
        restart_trustee(Cluster(args.context), args.namespace, args.timeout, args.trustee_name)
    except (Incomplete, ValueError, KeyError, TypeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print("New Trustee serving pods verified against current configuration and collateral mounts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
