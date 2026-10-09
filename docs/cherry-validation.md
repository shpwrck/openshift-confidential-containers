# Cherry setup

The [October 8 trial](validation/README.md) passed and was retired. This guide
starts with **new, already allocated** servers. Cherry provisioning is manual;
the repository automates preparation and installation after the helper is ready.

## Prerequisites

- One AMD SNP bare-metal node and a separate mirror/admin helper in the same region,
  with a working private VLAN. Confirm current price and a total budget before allocation.
- Console access for [BIOS configuration](amd-firmware-preflight.md). The tested
  H13SST-G needed manual setup; its Redfish BIOS API required a licence.
- A prepared TLS mirror registry on the helper. Red Hat documents RHEL as its supported
  host; the trial's AlmaLinux 9.8 helper was a compatibility test.
  The shared [cloud-init bootstrap](../ansible/bootstrap/mirror-registry.yaml.j2) uses
  Jinja inputs for the actual helper network, registry archive/checksum and SSH user;
  render it with protected external values before uploading it to the provider.
- Private DNS and NTP, no upstream DNS forwarding for the node, and no private-to-public
  forwarding through the helper. The helper may remain connected for staging content.
- External credentials, pinned SSH access and environment inputs from the [quickstart](current-quickstart.md).

Load the provider key through `CHERRY_SERVERS_API_KEY` without putting its value in
shell history or the checkout. Select `infra_provider: cherry` and
`network_profile: private-vlan`. Allocation is separate from the repository installation wrapper.

## Network and identity inputs

Check the actual server/project/hostname against authenticated provider inventory.
Read NIC names, permanent MACs and the VLAN wire tag from the raw OS. The provider's
VLAN object ID is a different value from the tag carried on the wire.

The validated network used an 802.3ad bond with two physical members. For this layout,
each machine needs `provider_hostname`, `provider_project_id`, `parent_if`,
`parent_mac`, `bond_mode: 802.3ad`, and `bond_ports: [{name, mac}, ...]`.
Set `external_if` empty only when there is no separate public NIC. The rendered
bond has no public address; only its private VLAN child gets an address.

Set the helper's `bastion_private_if` and `bastion_external_if` from its actual
interfaces. Configure `raw_node_ssh_user`, `raw_node_ssh_key`, `bastion_ssh_key` and
`private_link_known_hosts` explicitly. Verify the installation disk by serial and
stable path; do not reuse disk or interface values from the retired allocation.

## Install

With the raw node's private network configured and BIOS/SNP preflight complete:

```bash
bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags render,pxe -e install_mode=fresh \
  -e "@$COCO_STATE_DIR/rig.yml"
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/qualify-private-link.yml -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

The qualification step checks raw-node registry TLS, DNS, NTP and direct private
routing. It submits no rebuild. Fresh install repeats that check before a new request.
After an accepted rebuild, use `--mode resume-install` with unchanged inputs if needed.

The trial used a tokenized public iPXE endpoint to deliver initial boot artifacts.
The Agent OS, installed node and workloads then used private networking. Private
boot delivery from power-on requires a separate test. Successful installation removes
the temporary publication; [troubleshooting](troubleshooting.md) covers interrupted runs.

Continue with the [CoCo/Trustee steps](current-quickstart.md#install-coco-and-trustee)
and [capability proofs](capability-status.md). Each new allocation needs fresh
hardware, collateral, reference and isolation evidence.
