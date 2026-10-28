#!/usr/bin/env python3
"""Check the AMD node over pinned SSH before the install erases it.

The install's erase confirmation runs this on the controller. It reads the
node's identity and boot mode, describes the install disk, runs the SEV-SNP host
check, and saves the output in the evidence directory. It prints JSON for
Ansible and exits 1 when any check fails. Nothing on the node is changed.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from node_checks import NodeUnreachable, check_node, save_evidence  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", required=True, help="the node's public IPv4, from the provider")
    parser.add_argument("--user", required=True)
    parser.add_argument("--key", required=True, help="SSH private key")
    parser.add_argument("--known-hosts", required=True, help="the pinned known_hosts file")
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--hostname", default="", help="the hostname the provider reports")
    parser.add_argument("--root-device", default="", help="the rig file's node_root_device")
    parser.add_argument("--evidence-dir", required=True)
    args = parser.parse_args(argv)
    ssh = ["ssh", "-i", args.key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={args.known_hosts}",
           "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15", f"{args.user}@{args.address}"]

    def run(command, stdin):
        return subprocess.run([*ssh, command], input=stdin, capture_output=True, text=True, timeout=600)

    try:
        report = check_node(run, args.hostname, args.root_device)
    except (NodeUnreachable, subprocess.TimeoutExpired) as error:
        print(json.dumps({"passed": False, "problems": [f"no SSH to the node at {args.address}: {error}"],
                          "lines": [], "evidence": ""}))
        return 1
    evidence = save_evidence(report, args.evidence_dir, args.server_id, args.address)
    print(json.dumps({**{k: report[k] for k in ("passed", "problems", "lines", "install_disk", "snp_output")},
                      "evidence": str(evidence)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
