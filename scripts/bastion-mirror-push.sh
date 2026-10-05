#!/usr/bin/env bash
# Retired duplicated baseline helper; keep a clear migration message for old runbooks.
set -euo pipefail
cat >&2 <<'MESSAGE'
This historical helper has been retired. The maintained path validates release inputs,
uses external environment files, and preserves installation/reinstall state.
From the checkout on the controller, use:
  ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook ansible/playbooks/site.yml --tags mirror -e @/absolute/external/rig.yml
See docs/current-quickstart.md before running a phase on the selected bastion.
MESSAGE
exit 2
