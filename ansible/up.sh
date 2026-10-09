#!/usr/bin/env bash
# Preparation is the default. A machine reinstall requires --mode fresh-install.
# Provision the Cherry rig separately; this wrapper prepares and installs supplied hosts.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MODE=prepare
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "ERROR: --mode needs prepare, fresh-install, resume-install, or verify" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --apply-tf|--plan-tf)
      echo "ERROR: provisioning flags have been removed; supply an allocated Cherry rig" >&2
      exit 2 ;;
    --help|-h)
      echo "Usage: $0 [--mode prepare|fresh-install|resume-install|verify] [Ansible options]"
      echo "prepare: mirror/tools/DNS only (default); fresh-install: explicit machine reinstall; resume-install: finish an accepted request; verify: read-only cluster release check"
      echo "Keep credentials and generated state in COCO_STATE_DIR outside the checkout."
      exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$MODE" in prepare|fresh-install|resume-install|verify) ;; *) echo "ERROR: unsupported mode '$MODE'; in-place upgrades require a separate supported procedure" >&2; exit 2 ;; esac
# Bash 3.2 treats empty arrays as unset under nounset; conditional expansion below
# preserves zero arguments for empty arrays and boundaries for populated arrays.
EXTRA=("$@")
COCO_STATE_DIR="${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}"
# Generated state may contain credentials. Resolve existing symlink parents too.
COCO_STATE_DIR="$(python3 - "$COCO_STATE_DIR" "$REPO" <<'PY'
from pathlib import Path
import sys
state, repo = (Path(p).expanduser().resolve() for p in sys.argv[1:])
for forbidden in (repo, Path('/mnt/c/homelab')):
    if str(state).lower() == str(forbidden).lower() or str(state).lower().startswith(str(forbidden).lower() + '/'):
        raise SystemExit('ERROR: COCO_STATE_DIR must be outside the checkout and Homelab; select a private external state directory')
print(state)
PY
)"
export COCO_STATE_DIR
# Normalize selected input paths before entering the Ansible directory.
for config_var in RELEASE_MANIFEST IMAGESET_CONFIG; do
  if [[ -n "${!config_var:-}" ]]; then
    printf -v "$config_var" '%s' "$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "${!config_var}")"
    export "${config_var?}"
  fi
done
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$HERE/ansible.cfg}"
cd "$HERE"
if [[ "$MODE" == verify ]]; then
  ansible-playbook playbooks/site.yml --tags drive ${EXTRA[@]+"${EXTRA[@]}"} -e install_mode=verify
  exit
fi
if [[ "$MODE" == resume-install ]]; then
  # Reuse prepared assets and an accepted journal. The role refuses a missing,
  # ambiguous or changed request before any provider call; no raw-OS discovery.
  ansible-playbook playbooks/site.yml --tags drive ${EXTRA[@]+"${EXTRA[@]}"} -e install_mode=fresh -e resume_install_only=true
  ansible-playbook playbooks/site.yml --tags pxe-stop ${EXTRA[@]+"${EXTRA[@]}"}
  echo "Accepted installation completed; boot-artifact endpoint closed."
  exit
fi
# Check the complete product BOM before changing the supplied bastion.
# shellcheck source=scripts/lib/release.sh
source "$REPO/scripts/lib/release.sh"
load_release_defaults
if [[ "$MODE" == fresh-install && "${TEE:-snp}" != snp ]]; then
  echo "ERROR: fresh-install currently validates AMD SEV-SNP hardware only" >&2
  exit 2
fi
require_resolved_release
echo "Prepare the bastion and verify the requested mirror inputs"
ansible-playbook playbooks/site.yml --tags bastion-prep ${EXTRA[@]+"${EXTRA[@]}"}
[[ "$MODE" == fresh-install ]] || exit 0
echo "Fresh installation: selected provider machines will be reinstalled after the BIOS gate"
ansible-playbook playbooks/site.yml --tags install ${EXTRA[@]+"${EXTRA[@]}"} -e install_mode=fresh
# Close the secret-bearing endpoint as part of successful installation.
ansible-playbook playbooks/site.yml --tags pxe-stop ${EXTRA[@]+"${EXTRA[@]}"}
echo "Fresh installation completed; boot-artifact endpoint closed."
