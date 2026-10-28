"""The disposable lab's state directory, rig file and pinned SSH access to the helper.

make connect and make trustee-lab both use these. The rig file is the one that
make order-rig wrote in $COCO_STATE_DIR; the SSH options trust only the host keys
it pinned.
"""
import os
from pathlib import Path

import yaml  # From the controller requirements.

HELPER_KEYS = ("bastion_ssh_user", "bastion_ansible_host", "bastion_ssh_key", "private_link_known_hosts")


class Stop(Exception):
    """Something the operator has to fix first."""


def state_dir():
    """$COCO_STATE_DIR, which must hold the rig file."""
    value = os.environ.get("COCO_STATE_DIR")
    if not value or not (Path(value) / "rig.yml").is_file():
        raise Stop("no rig file found; run 'source scripts/env.sh' in this terminal, and make order-rig first")
    return Path(value)


def load_rig(state, required=HELPER_KEYS):
    rig = yaml.safe_load((state / "rig.yml").read_text()) or {}
    missing = [key for key in required if not rig.get(key)]
    if missing:
        raise Stop(f"the rig file has no {', '.join(missing)}")
    return rig


def helper_destination(rig):
    return f"{rig['bastion_ssh_user']}@{rig['bastion_ansible_host']}"


def ssh_options(rig):
    """ssh and its options for the helper; append extra options, the destination and a command."""
    return ["ssh", "-i", rig["bastion_ssh_key"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={rig['private_link_known_hosts']}",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15"]


def write_private(path, data):
    """Write text or bytes readable only by you, replacing the file in one step."""
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb" if isinstance(data, bytes) else "w") as handle:
        handle.write(data)
    os.replace(temporary, path)
