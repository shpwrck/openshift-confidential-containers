#!/usr/bin/env bash
# Preparation is the default. A machine reinstall requires --mode fresh-install.
# Order the rig first (make order-rig); this wrapper prepares and installs it.
# Without a vars file it uses the rig file $COCO_STATE_DIR/rig.yml.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MODE=prepare
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "ERROR: --mode needs prepare, fresh-install, resume-install, or verify" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--mode prepare|fresh-install|resume-install|verify] [Ansible options]"
      echo "prepare: the helper's tools, mirror, DNS and NTP only (default)"
      echo "fresh-install: check the node and ask once, then prepare the helper, build the boot files,"
      echo "  check the private network, erase and install the node, and verify the cluster"
      echo "resume-install: finish an accepted install request; verify: read-only cluster release check"
      echo "Without -e @<file>, the rig file \$COCO_STATE_DIR/rig.yml is used."
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
if state == repo or repo in state.parents:
    raise SystemExit('ERROR: COCO_STATE_DIR must be outside the checkout; select a private external state directory')
print(state)
PY
)"
export COCO_STATE_DIR
# Check vars files and pass them as absolute paths before entering the Ansible
# directory. In a shell without COCO_STATE_DIR, "@$COCO_STATE_DIR/rig.yml" is "@/rig.yml".
vars_file_path() {
  [[ -f "$1" && -r "$1" ]] || {
    echo "ERROR: vars file '$1' not found; for the rig file, run 'source scripts/env.sh' in this terminal first: it sets COCO_STATE_DIR" >&2
    exit 2
  }
  python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$1"
}
CHECKED=()
expect_vars=0
vars_files=0
for arg in ${EXTRA[@]+"${EXTRA[@]}"}; do
  if (( expect_vars )) && [[ "$arg" == @* ]]; then
    arg="@$(vars_file_path "${arg#@}")"; vars_files=1
  elif [[ "$arg" == -e@* ]]; then
    arg="-e@$(vars_file_path "${arg#-e@}")"; vars_files=1
  elif [[ "$arg" == --extra-vars=@* ]]; then
    arg="--extra-vars=@$(vars_file_path "${arg#--extra-vars=@}")"; vars_files=1
  fi
  expect_vars=0
  if [[ "$arg" == -e || "$arg" == --extra-vars ]]; then expect_vars=1; fi
  CHECKED+=("$arg")
done
# The rig file make order-rig writes, unless another vars file was given. It comes
# first, so later -e values on the command line override it.
if (( ! vars_files )); then
  [[ -f "$COCO_STATE_DIR/rig.yml" ]] || {
    echo "ERROR: no rig file at $COCO_STATE_DIR/rig.yml. Run 'make order-rig' first, or pass -e @<rig file>." >&2
    echo "In a new terminal, run 'source scripts/env.sh' first: it sets COCO_STATE_DIR." >&2
    exit 2
  }
  CHECKED=(-e "@$(vars_file_path "$COCO_STATE_DIR/rig.yml")" ${CHECKED[@]+"${CHECKED[@]}"})
fi
EXTRA=(${CHECKED[@]+"${CHECKED[@]}"})
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
if [[ "$MODE" == fresh-install ]]; then
  # The node checks and the one question come first, so the long helper
  # preparation and the install then run without anyone at the terminal.
  echo "== Check the node and confirm its erase. Nothing is changed yet. =="
  ansible-playbook playbooks/site.yml --tags bios ${EXTRA[@]+"${EXTRA[@]}"}
  echo "Checks done and the erase confirmed; nothing has changed yet. The rest runs on its own."
fi
echo "== Prepare the helper: tools, mirror, DNS and NTP =="
ansible-playbook playbooks/site.yml --tags bastion-prep ${EXTRA[@]+"${EXTRA[@]}"}
[[ "$MODE" == fresh-install ]] || exit 0
echo "== Install the node: boot files, network check, erase and install (45 to 70 minutes) =="
ansible-playbook playbooks/site.yml --tags install --skip-tags bios ${EXTRA[@]+"${EXTRA[@]}"} -e install_mode=fresh
# Close the secret-bearing endpoint as part of successful installation.
ansible-playbook playbooks/site.yml --tags pxe-stop ${EXTRA[@]+"${EXTRA[@]}"}
echo "Fresh installation completed; boot-artifact endpoint closed."
