# Contributor setup

Use Python 3.12+ and an external virtual environment. Linux is the provisioning
controller; CI also checks portable workstation scripts on macOS.

```bash
umask 077
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
mkdir -p "$COCO_STATE_DIR"
python3 -m venv "$COCO_STATE_DIR/dev-venv"
source "$COCO_STATE_DIR/dev-venv/bin/activate"
python3 -m pip install -r requirements-dev.txt
make install-dev-tools
export PATH="$COCO_STATE_DIR/dev-bin:$PATH"
make lint
```

Install ShellCheck separately through your operating system's package manager.
`make install-dev-tools` fetches checksum-verified OPA/Kustomize. `make lint` runs
shell, policy, manifest, documentation-link and offline regression checks.
Local checks do not validate firmware or attestation.

For documentation-only edits, run `python3 scripts/check-doc-links.py` and
`git diff --check`. Keep commands aligned with `make help`, link to shared
instructions rather than copying them, and retain the date/scope of validation claims.

## Where commands run

| Location | Work |
|---|---|
| Linux controller | Ansible, release resolution and orchestration |
| Linux helper | Mirror, DNS/NTP, boot publication and artifact preparation |
| macOS or Linux workstation | Portable cluster/workload scripts with explicit contexts and required external inputs |
| AMD node / RHCOS | Host SNP check and commands invoked through node debug |

macOS's Bash 3.2 is supported for the portable script paths. Install the required
`oc`, `jq`, Python 3.12+, Skopeo/Cosign and Podman only for the operations you use.
Host-side hashing/base64 goes through `scripts/lib/compat.sh`; node-side GNU commands
run on Linux. Use Linux for provisioning even when driving portable scripts from macOS.
