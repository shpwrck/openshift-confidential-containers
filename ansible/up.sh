#!/usr/bin/env bash
# Preparation is the default. A machine reinstall requires --mode fresh-install.
# Supplied rigs can use Cherry or Latitude; Terraform modules remain Latitude-specific.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MODE=prepare
TF_ACTION=none
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "ERROR: --mode needs prepare, fresh-install, resume-install, or verify" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --apply-tf|--plan-tf)
      [[ "$TF_ACTION" == none ]] || { echo "ERROR: choose only one Terraform action" >&2; exit 2; }
      TF_ACTION="${1#--}"; TF_ACTION="${TF_ACTION%-tf}"; shift ;;
    --help|-h)
      echo "Usage: $0 [--mode prepare|fresh-install|resume-install|verify] [--plan-tf|--apply-tf] [Ansible options]"
      echo "prepare: mirror/tools/DNS only (default); fresh-install: explicit machine reinstall; resume-install: finish an accepted request; verify: read-only cluster release check"
      echo "--plan-tf performs Terraform planning only; it never runs Ansible or applies a plan."
      echo "Keep local secrets and Terraform state in COCO_STATE_DIR outside the checkout."
      exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$MODE" in prepare|fresh-install|resume-install|verify) ;; *) echo "ERROR: unsupported mode '$MODE'; in-place upgrades require a separate supported procedure" >&2; exit 2 ;; esac
[[ ( "$MODE" != verify && "$MODE" != resume-install ) || "$TF_ACTION" == none ]] || { echo "ERROR: $MODE cannot plan or apply Terraform" >&2; exit 2; }
# Bash 3.2 treats empty arrays as unset under nounset; conditional expansion below
# preserves zero arguments for empty arrays and boundaries for populated arrays.
EXTRA=("$@")
AUTO_EXTRA=()
COCO_STATE_DIR="${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}"
# Terraform's local state may contain credentials. Resolve existing symlink parents too.
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
tf() {
  local module="$1" name="$2" state_dir="$COCO_STATE_DIR/terraform/$2" varfile
  local tf_args=()
  if [[ "$name" == bastion ]]; then varfile="${COCO_BASTION_TFVARS:-}"; else varfile="${COCO_NODE_TFVARS:-}"; fi
  if [[ -n "$varfile" ]]; then
    [[ "$varfile" == /* && -f "$varfile" ]] || { echo "ERROR: $name tfvars must be an existing absolute external path" >&2; exit 2; }
    tf_args+=("-var-file=$varfile")
  fi
  if [[ "$TF_ACTION" != none ]]; then
    if [[ -f "$module/terraform.tfstate" ]]; then
      echo "ERROR: existing $name state is in the checkout; reconcile it with $state_dir before provisioning" >&2
      exit 2
    fi
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    export TF_DATA_DIR="$state_dir/data"
    terraform -chdir="$module" init -input=false
    if [[ "$name" == node ]]; then
      terraform -chdir="$module" "$TF_ACTION" -state="$state_dir/terraform.tfstate" ${tf_args[@]+"${tf_args[@]}"} \
        -var="bastion_state_path=$COCO_STATE_DIR/terraform/bastion/terraform.tfstate"
    else
      terraform -chdir="$module" "$TF_ACTION" -state="$state_dir/terraform.tfstate" ${tf_args[@]+"${tf_args[@]}"}
    fi
    if [[ "$TF_ACTION" == apply ]]; then
      if [[ "$name" == bastion ]]; then
        local bastion_ip vlan_vid
        bastion_ip="$(terraform -chdir="$module" output -state="$state_dir/terraform.tfstate" -raw bastion_public_ipv4)"
        vlan_vid="$(terraform -chdir="$module" output -state="$state_dir/terraform.tfstate" -raw virtual_network_vid)"
        AUTO_EXTRA+=(-e "bastion_ansible_host=$bastion_ip" -e "bastion_public_ipv4_override=$bastion_ip" -e "vlan_vid_override=$vlan_vid")
      else
        local server_id
        server_id="$(terraform -chdir="$module" output -state="$state_dir/terraform.tfstate" -raw server_id)"
        AUTO_EXTRA+=(-e "node_server_id=$server_id")
      fi
    fi
  else
    echo "Terraform $name unchanged; pass --apply-tf to provision it using external state."
  fi
}
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
# Check the complete product BOM before spending on infrastructure or changing a bastion.
# shellcheck source=scripts/lib/release.sh
source "$REPO/scripts/lib/release.sh"
load_release_defaults
if [[ "$MODE" == fresh-install && "${TEE:-snp}" != snp ]]; then
  echo "ERROR: fresh-install currently validates AMD SEV-SNP hardware only" >&2
  exit 2
fi
require_resolved_release
echo "Prepare the bastion and verify the requested mirror inputs"
tf "$REPO/infra/latitude/bastion" bastion
if [[ "$TF_ACTION" == plan ]]; then
  [[ "$MODE" != fresh-install ]] || tf "$REPO/infra/latitude" node
  echo "Terraform planning finished; no infrastructure apply or Ansible run was requested."
  exit 0
fi
ansible-playbook playbooks/site.yml --tags bastion-prep ${AUTO_EXTRA[@]+"${AUTO_EXTRA[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
[[ "$MODE" == fresh-install ]] || exit 0
echo "Fresh installation: selected provider machines will be reinstalled after the BIOS gate"
tf "$REPO/infra/latitude" node
ansible-playbook playbooks/site.yml --tags install ${AUTO_EXTRA[@]+"${AUTO_EXTRA[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} -e install_mode=fresh
# Close the secret-bearing endpoint as part of successful installation.
ansible-playbook playbooks/site.yml --tags pxe-stop ${AUTO_EXTRA[@]+"${AUTO_EXTRA[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
echo "Fresh installation completed; boot-artifact endpoint closed."
