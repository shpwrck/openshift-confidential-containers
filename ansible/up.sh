#!/usr/bin/env bash
# Single entrypoint for the hands-off disconnected SNO air-gapped bring-up.
#
# Sequences the TF-owns-infra / Ansible-owns-host+install boundary:
#   1. terraform apply  bastion        (TF: persistent mirror/air-gap host)
#   2. ansible Phase A   bastion-prep  (egress -> tools -> mirror push -> dns/ntp)
#   3. terraform apply  node           (TF: disposable SNP node, operating_system=ipxe)
#   4. ansible Phase B+C discover + render + pxe-serve + install (reinstall netboot + wait)
#   5. STOP for the SEV-SNP BIOS (hard pause inside the playbook, before the install phase)
#
# This script does NOT run terraform itself by default (the repo rule forbids live applies in
# authoring); it PRINTS the terraform commands and runs only the Ansible halves. Pass --apply-tf
# to also run the terraform applies (interactive approval).
#
# Secrets come from the environment, never from committed files:
#   export LATITUDESH_AUTH_TOKEN=...   # Latitude API token (discover + reinstall)
#   The RH pull-secret must already be on the bastion at ~/pull-secret.json (Phase 0).
#
# Required -e overrides (from terraform output), or set them in a local group_vars file:
#   bastion_ansible_host        = bastion public IPv4 (SSH target)
#   bastion_public_ipv4_override= bastion public IPv4 (baked into the iPXE URL)
#   vlan_vid_override           = terraform output virtual_network_vid
#   node_server_id              = the node's Latitude server id
#   boot_artifacts_token        = openssl rand -hex 16
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APPLY_TF=0
[[ "${1:-}" == "--apply-tf" ]] && { APPLY_TF=1; shift || true; }

EXTRA=("$@")  # pass-through -e overrides, e.g. ./up.sh -e vlan_vid_override=123 -e node_server_id=sv_x

tf() {
  if [[ "$APPLY_TF" == "1" ]]; then
    terraform -chdir="$1" init -input=false
    terraform -chdir="$1" apply
  else
    echo ">> (skipped — pass --apply-tf to run) terraform -chdir=$1 init && apply"
  fi
}

echo "=== 1/5 terraform apply BASTION (persistent mirror host) ==="
tf "$REPO/infra/latitude/bastion"

echo "=== 2/5 ansible Phase A — bastion prep (egress, tools, mirror, dns/ntp) ==="
ansible-playbook playbooks/site.yml --tags bastion-prep "${EXTRA[@]}"

echo "=== 3/5 terraform apply NODE (disposable SNP node, operating_system=ipxe) ==="
tf "$REPO/infra/latitude"

echo "=== 4+5/5 ansible discover + install (STOPS for SEV-SNP BIOS before netboot) ==="
ansible-playbook playbooks/site.yml --tags install "${EXTRA[@]}"

echo
echo "=== bring-up driven. After the node has booted, CLOSE the boot endpoint: ==="
echo "    ansible-playbook playbooks/site.yml --tags pxe-stop ${EXTRA[*]}"
