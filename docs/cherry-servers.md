# Cherry Servers setup

The [October 8 trial](validation/README.md) ran on Cherry Servers. This guide
lists what you need from Cherry and where to find each value. Allocating the
servers is a manual step in the Cherry portal; the repository automates
everything after the helper is running.

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
- External credentials, pinned SSH access and environment inputs from the [quickstart](quickstart.md).

Export your Cherry API key as `CHERRY_SERVERS_API_KEY` without putting it in shell
history or the checkout (the quickstart shows one way). Cherry and the private VLAN
network profile are the defaults, so the rig file does not need to select them.

## Where to find each rig-file value

Read every value from the servers you were given, not from an old rig. The
[example rig file](../ansible/rig.example.yml) has a placeholder for each.

| Rig-file key | Where to read it |
|---|---|
| `node_server_id`, `node_provider_hostname`, `node_provider_project_id` | Cherry portal or API for the node. The automation checks them against the API before reinstalling. |
| `node_parent_mac`, `node_bond_ports` (name and MAC of each member) | `ip link` on the node's original OS. Use permanent MACs. |
| `node_external_if`, `node_external_mac` | The node's separate public NIC, if it has one; otherwise leave empty. |
| `vlan_vid_override` | The VLAN tag on the wire, from the node's original network config. Cherry's VLAN object ID is a different number. |
| `bastion_private_if`, `bastion_external_if` | `ip link` on the helper. |
| `node_root_device` | A `/dev/disk/by-path/...` path on the node. Check the disk serial with `lsblk -o NAME,SERIAL,SIZE` first. |
| `raw_node_ssh_user`, `raw_node_ssh_key`, `bastion_ssh_key`, `private_link_known_hosts` | Your SSH access to both servers, with their host keys pinned in the `known_hosts` file. |

The tested network was an 802.3ad (LACP) bond of two physical NICs. The installed
bond has no public address; only its private VLAN interface gets one.

## Install

Once the servers are allocated, the BIOS is set and the node's private VLAN is
configured in its original OS, follow the [quickstart](quickstart.md) from step 1.
Steps 3 to 5 prepare the helper, check the node's private network and install
OpenShift.

The trial delivered the first boot files to the node over the helper's public IP,
protected by a random token in the URL. Everything after that (the installer
environment, the installed node and the workloads) used only the private VLAN.
Booting entirely over the private network from power-on has not been tested.
Successful installation removes the public boot files;
[troubleshooting](troubleshooting.md) covers interrupted runs.

Each new allocation needs its own hardware checks, VCEK certificates, reference
values and isolation evidence. Do not reuse values from the retired trial.
