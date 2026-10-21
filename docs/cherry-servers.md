# Cherry Servers setup

The [October 8 trial](validation.md) ran on Cherry Servers. This guide orders the
servers with the [Terraform in `infra/cherry`](../infra/cherry/) and says where each
rig-file value comes from. Ansible does everything after the servers are up.

## Prerequisites

- A Cherry Servers project and API key, and a budget: confirm the hourly price of both
  plans before ordering. The servers bill until you [retire them](maintenance.md#retire-the-infrastructure).
- An AMD EPYC bare-metal plan whose board supports SEV-SNP for the node, and any plan
  with enough disk for the mirror for the helper. Red Hat documents RHEL as the
  supported mirror-registry host; the trial's AlmaLinux 9.8 helper was a compatibility test.
- Console access for [BIOS configuration](amd-firmware-preflight.md). The tested
  H13SST-G needed manual setup; its Redfish BIOS API required a licence.
- Private DNS and NTP, no upstream DNS forwarding for the node, and no private-to-public
  forwarding through the helper. Ansible sets these up; the helper may remain connected
  for staging content.
- The controller from [quickstart step 1](quickstart.md#1-set-up-the-controller), plus
  Terraform 1.9 or later (CI uses 1.16.5).

Export your Cherry API key as `CHERRY_SERVERS_API_KEY` without putting it in shell
history or the checkout (the quickstart shows one way). Cherry and the private VLAN
network profile are the defaults, so the rig file does not need to select them.

## Order the servers

Cherry puts both servers on the project's private VLAN in that region and configures
it in their original OS as a tagged child of the uplink (for example `bond0.2738`).
The helper's first-boot bootstrap adopts that interface and its address, so nothing
from the order has to go back into its user data.

1. Pick a versioned mirror-registry archive (the trial used 2.0.12; `/latest/` links are
   refused). Use the release's published SHA-256 if it has one; otherwise download the
   archive once on a trusted machine and run `sha256sum` on it.
2. Render the helper's cloud-init user data. The file holds no secrets: the registry
   password is generated on the helper.

   ```bash
   python3 scripts/render-helper-bootstrap.py \
     --ssh-user '<helper-image-login-user>' \
     --mirror-registry-url '<versioned-archive-url>' \
     --mirror-registry-sha256 '<archive-sha256>' \
     > "$COCO_STATE_DIR/helper-user-data.yaml"
   ```

   The registry name (`mirror.rig.local`), `/opt/mirror` and registry user `init` match
   [`group_vars/all.yml`](../ansible/group_vars/all.yml). Run the script with `--help`
   to change them, or to give an explicit VLAN tag and address instead of adopting them.

3. Fill in the Terraform variables: project, region, plan and image slugs, and the
   SSH public key for both servers.

   ```bash
   cp infra/cherry/terraform.tfvars.example "$COCO_STATE_DIR/cherry.tfvars"
   ```

4. Order both servers. State and the provider cache stay in `COCO_STATE_DIR`; keep these
   two exports for every `terraform` command below.

   ```bash
   export CHERRY_API_KEY="$CHERRY_SERVERS_API_KEY" TF_DATA_DIR="$COCO_STATE_DIR/terraform"
   terraform -chdir=infra/cherry init -backend-config="path=$COCO_STATE_DIR/cherry.tfstate"
   terraform -chdir=infra/cherry apply -var-file="$COCO_STATE_DIR/cherry.tfvars"
   ```

   `init` checks the provider against the committed lock file and may add your
   platform's hash to it. The apply ends with an error, after ordering, if the two
   servers did not land on the same private network: Cherry VLANs do not span
   switches. Replace the helper with
   `terraform -chdir=infra/cherry apply -var-file="$COCO_STATE_DIR/cherry.tfvars" -replace=cherryservers_server.helper`,
   or ask Cherry support to move it.

5. Start the rig file with the values Cherry assigned: both public and private
   addresses, the node's server ID, hostname and project, the private network and the
   VLAN tag the API reports.

   ```bash
   cp ansible/rig.example.yml "$COCO_STATE_DIR/rig.yml"
   terraform -chdir=infra/cherry output -raw rig_values >> "$COCO_STATE_DIR/rig.yml"
   ```

6. Check the helper. `MIRROR_READY` means the registry is serving; `MIRROR_FAILED`
   means a step failed, and the log says which. `rig-network.env` names the adopted
   interface: its `VLAN_IFACE` is `bastion_private_if`, its `PUBLIC_IFACE` is
   `bastion_external_if`, and its `VLAN_VID` must equal `vlan_vid_override`.

   ```bash
   ssh '<helper-image-login-user>'@"$(terraform -chdir=infra/cherry output -raw helper_public_ipv4)"
   sudo ls /opt/mirror/MIRROR_READY /opt/mirror/MIRROR_FAILED
   sudo tail -n 20 /var/log/mirror-bootstrap.log
   cat /etc/rig-network.env
   ```

7. Check the node's tag on its original OS. The number after `id` must equal
   `vlan_vid_override`; Ansible checks it again before installing.

   ```bash
   ip -d link show type vlan | grep -o '802.1Q id [0-9]*'
   ```

Terraform never reinstalls the node after ordering: Ansible rebuilds it into
OpenShift through the Cherry API, and the configuration ignores that drift.

### Ordering in the portal instead

Order both servers together in one region and project, so they share a switch, and
paste the rendered file into the helper's cloud-init user data field. Then copy the
provider values into the rig file by hand, using the table below.

## Where to find each rig-file value

Read every value from the servers you were given, not from an old rig. The
[example rig file](../ansible/rig.example.yml) has a placeholder or a commented line for each.

`terraform output rig_values` supplies the provider values; read the rest from the
servers themselves.

| Rig-file key | Where to read it |
|---|---|
| `node_server_id`, `node_provider_hostname`, `node_provider_project_id` | `rig_values`, or the Cherry portal or API for the node. The automation checks them against the API before reinstalling. |
| `bastion_ansible_host`, `bastion_public_ipv4_override` | `rig_values`, or the helper's public IPv4 in the portal. |
| `node_vlan_ip`, `bastion_vlan_ip`, `machine_network`, `vlan_cidr`, `vlan_prefix` | `rig_values`, or each server's private IPv4 and its network. Cherry assigns these; the `group_vars` defaults do not apply on Cherry. |
| `node_parent_mac`, `node_bond_ports` (name and MAC of each member) | `ip link` on the node's original OS. Use permanent MACs. |
| `node_external_if`, `node_external_mac` | The node's separate public NIC, if it has one; otherwise leave empty. |
| `vlan_vid_override` | `rig_values`, checked against the node's original network config (step 7 above). It is the tag on the wire, not a VLAN object ID. |
| `bastion_private_if`, `bastion_external_if` | `VLAN_IFACE` and `PUBLIC_IFACE` in the helper's `/etc/rig-network.env`. |
| `node_root_device` | A `/dev/disk/by-path/...` path on the node. Check the disk serial with `lsblk -o NAME,SERIAL,SIZE` first. |
| `raw_node_ssh_user`, `raw_node_ssh_key`, `bastion_ssh_key`, `private_link_known_hosts` | Your SSH access to both servers, with their host keys pinned in the `known_hosts` file. |

The tested network was an 802.3ad (LACP) bond of two physical NICs. The installed
bond has no public address; only its private VLAN interface gets one.

## Install

Once the servers are ordered and the BIOS is set, follow the
[quickstart](quickstart.md) from step 2.
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
