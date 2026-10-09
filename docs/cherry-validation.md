# Cherry validation

> **Trial retired:** the two Cherry servers, task project and SSH key were deleted after validation. [The retirement receipt](validation/cherry-retirement-2026-10-08.json) records verified absence and protected backups. A future run needs fresh allocations and inputs.

The October 8, 2026 trial completed a healthy OCP 4.20.39 cluster, all five selected Operators and a converged OSC 1.13.1 `kata-snp` runtime with Trustee 1.2.1. The Ubuntu, Agent-live, installed RHCOS and post-Kata SNP gates passed. Offline guest attestation and all five individual CPU allow/deny/recovery proofs passed. Private service checks and installed-node, ordinary-pod and confidential-guest isolation passed. All five also passed one fresh combined proof run; a clean CoCo software reset/reinstall also passed with fresh combined proofs. Automatic retirement is disabled at the owner's direction; the overall $150 cap remains. See the [platform receipt](validation/cherry-qualification-2026-10-08.json), [CPU proof record](validation/cherry-cpu-proofs-2026-10-08.json) and [current trial runbook](runbooks/cherry-qualification/README.md).

## What is being tested

Use a dedicated project with one AMD SNP node and a separate mirror/admin helper in the same region. The delivered node is EPYC 9124 / H13SST-G, BIOS 3.7, with UEFI enabled. The API's `amd-epyc-9124p` plan label is not the actual processor name. Verify the delivered hardware using [AMD firmware preflight](amd-firmware-preflight.md).

Both servers use an 802.3ad bond and a private VLAN on that bond. For this allocation the actual wire tag is 2064. The API's `vlan` object ID 1213 is not that wire tag. Read the configured VLAN and permanent physical MAC addresses on the raw OS. The Agent configuration keeps both bond members up, gives the bond no public IPv4/IPv6 address, and assigns only the private VLAN address.

The helper serves private DNS, NTP and the TLS registry. Its managed forwarding rule blocks private-VLAN traffic from leaving through the public underlay, including when Podman enables IP forwarding. DNS does not proxy node queries upstream. The helper itself remains connected while staging content. Provider iPXE fetched boot artifacts through the tokenized public helper endpoint before the Agent OS took over; fully private boot-artifact delivery from power-on is not proved by this trial. A temporary raw-host firewall rehearsal passed for IPv4 and IPv6; it was rolled back. Separate installed-node, ordinary-pod and confidential-guest probes passed, including trusted private registry access and a deliberately failing guest probe calibration.

BIOS setup is an accepted manual prerequisite for this trial. The included BMC console was used to set SMEE, full-memory RMP coverage, IOMMU and SEV-SNP Support to Enabled, and SEV-ES ASID Space Limit to 100. The licensed Redfish BIOS endpoint rejected access; no licence was purchased. Settings survived the Kata reboot, but always measure the actual host after any reinstall or firmware change.

## Use the prepared rig

Keep provider keys, pull secrets, SSH pins, boot tokens, Ansible environment files and state outside the checkout. The supplied-rig workflow needs `infra_provider: cherry`, the helper connection, exact allocated server/project/hostname, private addresses, VLAN wire tag, verified install disk and two physical bond members. Cherry discovery uses the authenticated API for ownership/IP checks and pinned SSH for actual NIC identities; it does not infer MAC addresses from a plan name.

Each machine includes `provider_hostname`, `provider_project_id`, `parent_if`, `parent_mac`, `bond_mode: 802.3ad` and a `bond_ports` list of `{name, mac}` records. Set `external_if` to an empty string. The helper needs `bastion_private_if` and `bastion_external_if` matching its actual VLAN/public route. Configure `raw_node_ssh_user`, `raw_node_ssh_key` and `private_link_known_hosts` explicitly.

```bash
# From the checkout, with private external rig inputs and the API key already loaded:
bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
# Build fresh-install artifacts without submitting a rebuild:
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags render,pxe -e install_mode=fresh \
  -e "@$COCO_STATE_DIR/rig.yml"
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/qualify-private-link.yml -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

If the controller stops after Cherry accepted the rebuild, retain the same external inputs and run `bash ansible/up.sh --mode resume-install -e "@$COCO_STATE_DIR/rig.yml"`. The accepted-journal gate forbids a new request in this mode; it does not try to log into the replaced provider OS.

The qualification command requires already prepared boot files and reuses the exact check performed before a new rebuild. It sends no rebuild request. Fresh install journals intent before calling Cherry's `rebuild` action with a base64-encoded iPXE script; an accepted or ambiguous request is not silently repeated. A successful fresh install checks the release and health, then closes boot publication. An unresolved failure retains diagnostics and closes publication when no accepted request needs it.

Initial provisioning and mirror installation for this dated trial used the protected controller recorded in the runbook. Cherry provisioning is not implemented by the repository's Terraform modules. Do not use `--apply-tf` or `--plan-tf` for a Cherry rig; those modules target Latitude. The trial's AlmaLinux 9.8 helper is a lab compatibility test; Red Hat documents RHEL as the supported mirror-registry host.

## Fixes discovered during preparation

- Reuse an installed curl command, including `curl-minimal`, instead of requesting a conflicting full package.
- Open DNS, NTP and the registry with separate firewalld operations in both bootstrap and Ansible; fail when the managed firewall commands fail.
- Validate bundle-backed OLM plans through their `bundleLookups`: exact CSV, bundle digest and catalog reference. This OCP release omits source fields on the individual plan steps.
- Configure the helper's private API hostname before the installer wait. On this trial the API was reachable by IP but the wait could not discover it until this mapping was present.
- Validate the registry leaf with strict X.509 checks before declaring it ready. The generated mirror-registry 2.0.12 leaf incorrectly included certificate-signing usage. The lab repair retains the CA and server key, issues a valid server leaf and uses the supported certificate-rotation command. Arbitrary trust failures do not replace the CA automatically.

Preparation success alone does not establish the platform or guest proofs. This trial subsequently completed the platform and individual CPU checks, as recorded above; encrypted-image support is not established. Use [the capability ladder](capability-status.md) after the platform checks. Record positive controls, attributable denials and recovery, then run a clean repeat before calling the workflow validated.
