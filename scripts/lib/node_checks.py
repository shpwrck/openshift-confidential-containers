"""Read-only checks on the AMD node's original OS before it is erased.

`make check-node-snp` and the install's erase confirmation both use these. They
read the machine's identity and boot mode, describe the install disk, and run
scripts/host-snp-check.sh. Nothing on the node is changed.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex

REPO = Path(__file__).resolve().parents[2]
SNP_CHECK = REPO / "scripts/host-snp-check.sh"
# Run with `python3 - <install disk>` on the node's original OS (Ubuntu ships python3).
IDENTIFY = r'''
import json, os, socket, subprocess, sys
def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""
dmi = "/sys/class/dmi/id"
cpu = next((line.split(":", 1)[1].strip() for line in read("/proc/cpuinfo").splitlines()
            if line.startswith("model name")), "")
disks = json.loads(subprocess.check_output(
    ["lsblk", "-J", "-b", "-d", "-o", "NAME,PATH,TYPE,SIZE,SERIAL,MODEL,TRAN"]))["blockdevices"]
root = sys.argv[1] if len(sys.argv) > 1 else ""
print(json.dumps({
    "hostname": socket.gethostname(), "cpu": cpu,
    "system": " ".join(filter(None, (read(dmi + "/sys_vendor"), read(dmi + "/product_name")))),
    "board": read(dmi + "/board_name"), "bios_version": read(dmi + "/bios_version"),
    "bios_date": read(dmi + "/bios_date"), "uefi": os.path.isdir("/sys/firmware/efi"),
    "root_device": root, "root_path": os.path.realpath(root) if root and os.path.exists(root) else "",
    "disks": [d for d in disks if d.get("type") == "disk"]}))
'''


class NodeUnreachable(RuntimeError):
    """SSH to the node failed, so nothing was checked."""


def describe_disk(disk):
    size = f"{int(disk.get('size') or 0) / 1e9:.0f} GB"
    parts = [disk.get("path") or "/dev/" + disk.get("name", "?"), size, disk.get("model") or "",
             f"serial {disk.get('serial')}" if disk.get("serial") else "no serial reported"]
    return ", ".join(p.strip() for p in parts if p and p.strip())


def check_node(ssh, expected_hostname="", root_device=""):
    """Run the checks through `ssh(command, stdin)`, which returns a CompletedProcess."""
    command = "python3 -" + (" " + shlex.quote(root_device) if root_device else "")
    identity = ssh(command, IDENTIFY)
    if identity.returncode == 255:
        raise NodeUnreachable(identity.stderr.strip() or "ssh exited 255")
    try:
        facts = json.loads(identity.stdout)
    except ValueError:
        raise NodeUnreachable("the node did not report its identity: "
                              + (identity.stderr.strip() or identity.stdout.strip())) from None
    snp = ssh("bash -s", SNP_CHECK.read_text())
    if snp.returncode == 255:
        raise NodeUnreachable(snp.stderr.strip() or "ssh exited 255")
    problems, lines = [], []
    lines.append(f"Machine: {facts['hostname']}, {facts['cpu'] or 'CPU not reported'}")
    lines.append(f"System: {facts['system'] or 'not reported'}, board {facts['board'] or 'not reported'}, "
                 f"BIOS {facts['bios_version'] or '?'} ({facts['bios_date'] or 'no date'})")
    if expected_hostname and facts["hostname"] != expected_hostname:
        problems.append(f"the node calls itself {facts['hostname']}, but the provider names it {expected_hostname}")
    if facts["uefi"]:
        lines.append("PASS  booted in UEFI mode")
    else:
        problems.append("the node did not boot in UEFI mode, which the installer needs")
    if snp.returncode == 0:
        lines.append("PASS  SEV-SNP host check")
    else:
        problems.append("the SEV-SNP host check did not pass")
    install_disk = None
    if root_device:
        install_disk = next((d for d in facts["disks"] if d.get("path") == facts["root_path"]), None)
        if install_disk is None:
            problems.append(f"the install disk {root_device} is not a disk on the node")
        else:
            lines.append(f"Install disk: {root_device}")
            lines.append(f"  = {describe_disk(install_disk)}")
            others = [d for d in facts["disks"] if d is not install_disk and d.get("tran") != "usb"]
            for disk in others:
                lines.append(f"  other disk, left as it is: {describe_disk(disk)}")
    for problem in problems:
        lines.append(f"FAIL  {problem}")
    return {"passed": not problems, "problems": problems, "lines": lines, "facts": facts,
            "install_disk": install_disk, "snp_rc": snp.returncode,
            "snp_output": snp.stdout + snp.stderr}


def save_evidence(report, directory, server_id, address):
    """Keep the full output with the machine it came from, readable only by you."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}"
    text = (f"server {server_id} at {address}\n" + "\n".join(report["lines"]) + "\n\n"
            + json.dumps(report["facts"], indent=2) + "\n\n" + report["snp_output"]
            + f"exit={report['snp_rc']}\n")
    for attempt in range(1, 100):
        suffix = f"-{attempt}" if attempt > 1 else ""
        path = directory / f"host-snp-check-{server_id}-{stamp}{suffix}.txt"
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:  # another check in the same second
            continue
    else:
        raise FileExistsError(f"too many evidence files named {path}")
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    return path
