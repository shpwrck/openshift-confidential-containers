# Cherry Servers setup

The [October 8 trial](validation.md) ran on Cherry Servers. This guide orders the
servers with the [Terraform in `infra/cherry`](../infra/cherry/) and says where each
rig-file value comes from. Ansible does everything after the servers are up.

## Prerequisites

- A Cherry Servers project and [API key](https://portal.cherryservers.com/settings/api-keys),
  and a budget: confirm the hourly price of both plans before ordering. The servers bill until you [retire them](maintenance.md#retire-the-infrastructure).
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
It also installs the order's SSH key for `root`. Cherry skips both when a server is
ordered with cloud-init user data, so the helper is ordered plain, like the node, and
its mirror bootstrap runs over SSH afterwards. The bootstrap adopts the VLAN interface
and address Cherry configured.

1. Pick a versioned mirror-registry archive; `/latest/` links are refused. Red Hat lists
   each version under <https://mirror.openshift.com/pub/cgw/mirror-registry/>, with the
   archive's SHA-256 in that version's signed `sha256sum.txt`. The trial used 2.0.12;
   its x86_64 archive and checksum are in the command below.
2. Render the helper's bootstrap script. It holds no secrets: the registry password is
   generated on the helper.

   ```bash
   python3 scripts/render-helper-bootstrap.py \
     --mirror-registry-url 'https://developers.redhat.com/content-gateway/file/pub/cgw/mirror-registry/2.0.12/mirror-registry-amd64.tar.gz' \
     --mirror-registry-sha256 '6de43edfd77a61bb27116bb7a9a5715884722a811f92cd5d9dfca406afb457b2' \
     > "$COCO_STATE_DIR/helper-bootstrap.sh"
   ```

   The registry name (`mirror.rig.local`), `/opt/mirror` and registry user `init` match
   [`group_vars/all.yml`](../ansible/group_vars/all.yml). Run the script with `--help`
   to change them, to give an explicit VLAN tag and address instead of adopting them,
   or to print cloud-init user data for a provider that keeps its own setup with it.

3. Fill in the Terraform variables: project, region, plan and image slugs, and the
   SSH key for both servers. [Choosing the Terraform variables](#choosing-the-terraform-variables)
   says what each one means and how to look it up. Terraform refuses to plan while an
   example value is left.

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

   `init` checks the provider against the committed lock file. Bare-metal delivery can
   take 20 minutes or more. The apply ends with an error, after ordering, if the two
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

   Both servers log in as `root`, so set `bastion_ssh_user` and `raw_node_ssh_user` to
   `root`. If your key has a passphrase, load it into an agent first
   (`eval "$(ssh-agent -s)" && ssh-add <private-key>`): SSH and Ansible then stop
   asking for it.

6. Start the bootstrap on the helper. It runs as a systemd unit, as cloud-init would,
   so it keeps going after SSH disconnects and refuses to start a second time.

   ```bash
   ssh root@"$(terraform -chdir=infra/cherry output -raw helper_public_ipv4)" \
     'install -m 700 /dev/stdin /usr/local/sbin/helper-bootstrap.sh && systemd-run --unit=helper-bootstrap /usr/local/sbin/helper-bootstrap.sh' \
     < "$COCO_STATE_DIR/helper-bootstrap.sh"
   ```

7. Check the helper. The bootstrap installs packages, then downloads and installs the
   registry, so allow a while. `MIRROR_READY` means the registry is serving;
   `MIRROR_FAILED` means a step failed, and the log says which. `rig-network.env`
   names the adopted interface: its `VLAN_IFACE` is `bastion_private_if`, its
   `PUBLIC_IFACE` is `bastion_external_if`, and its `VLAN_VID` must equal
   `vlan_vid_override`.

   ```bash
   ssh root@"$(terraform -chdir=infra/cherry output -raw helper_public_ipv4)" \
     'systemctl status helper-bootstrap --no-pager --lines=0
      ls /opt/mirror/MIRROR_READY /opt/mirror/MIRROR_FAILED
      tail -n 20 /var/log/mirror-bootstrap.log
      cat /etc/rig-network.env'
   ```

   Before the registry step starts, `journalctl -u helper-bootstrap` on the helper
   shows the progress.

8. Check the node's tag on its original OS. The number after `id` must equal
   `vlan_vid_override`; Ansible checks it again before installing.

   ```bash
   ssh root@"$(terraform -chdir=infra/cherry output -raw node_public_ipv4)" \
     "ip -d link show type vlan | grep -o '802.1Q id [0-9]*'"
   ```

9. Pin both host keys for Ansible. Steps 6 and 8 added them to your own
   `known_hosts`; Ansible reads only the file `private_link_known_hosts` names and
   refuses any host missing from it. Expect several lines: after the first login
   OpenSSH also records each server's other host key types.

   ```bash
   { ssh-keygen -F "$(terraform -chdir=infra/cherry output -raw helper_public_ipv4)"
     ssh-keygen -F "$(terraform -chdir=infra/cherry output -raw node_public_ipv4)"; } \
     | grep -v '^#' > "$COCO_STATE_DIR/known_hosts"
   cut -d' ' -f2 "$COCO_STATE_DIR/known_hosts"
   ```

Terraform never reinstalls the node after ordering: Ansible rebuilds it into
OpenShift through the Cherry API, and the configuration ignores that drift.

### Choosing the Terraform variables

A few Cherry Servers terms first. A **team** is the billing account. A **project**
inside it holds servers and gives the servers in each region a shared private VLAN.
A **region** is a data center. A **plan** is a hardware model, and an **image** is the
operating system Cherry installs on delivery. Plans are ordered from stock, so a plan
can be listed in a region with none available. API keys are created at
<https://portal.cherryservers.com/settings/api-keys>; the commands below that need one
read `CHERRY_SERVERS_API_KEY`.

| Variable | What to set | How to look it up |
|---|---|---|
| `project_id` | The numeric ID of the project to order into. Use a project with nothing else in it, so the rig's VLAN holds only these two servers. | `GET /v1/teams` for your team ID, then `GET /v1/teams/<team-id>/projects` (commands below). |
| `region` | One region for both servers, with stock of both plans. The trial used `US-Chicago`. | The plan list below shows the stock per region. |
| `node_plan` | A bare-metal AMD EPYC plan. SEV-SNP needs an EPYC 7003, 8004, 9004 or 9005 series CPU (not Ryzen, EPYC 4004 or EPYC 7002), and a board and BIOS that expose it, which the [firmware preflight](amd-firmware-preflight.md) checks. The trial used `amd-epyc-9124p`. | The plan list below. |
| `node_image` | Any Linux image the plan offers. It only runs the firmware preflight; Ansible later replaces it with OpenShift. SNP host support was first shown on Ubuntu 26.04 (`ubuntu_26_04_64bit`, kernel 7.0). | `GET /v1/plans/<plan>/images`. |
| `helper_plan` | The cheapest plan in the same region with stock and enough disk for the mirror. It needs no SEV-SNP. | The plan list below, without the EPYC filter. |
| `helper_image` | `almalinux_9_64bit`. Cherry offers no RHEL image; Red Hat supports RHEL for mirror-registry, and AlmaLinux 9 was the trial's compatibility test. | `GET /v1/plans/<plan>/images`. |
| `ssh_public_key_file` or `ssh_key_ids` | One key for both servers. Give a public key file to register it, or the numeric ID of a key already in your account. Keep its private half: the rig file's `raw_node_ssh_key` and `bastion_ssh_key` use it. | `GET /v1/ssh-keys` lists your keys and their IDs. |
| `node_hostname`, `helper_hostname`, `billing_cycle`, `tags` | Optional. Billing defaults to `hourly`: both servers bill from ordering until they are [retired](maintenance.md#retire-the-infrastructure). | |

The plan list and the image lists are public. This shows each bare-metal EPYC plan's
hourly price in euros and the regions with stock:

```bash
curl -s https://api.cherryservers.com/v1/plans | jq -r '.[]
  | select(.type == "baremetal" and (.specs.cpus.name | test("EPYC")))
  | "\(.slug)  \([.pricing[] | select(.unit == "Hourly") | .price][0] // "-") EUR/h  \([.available_regions[] | select(.stock_qty > 0) | "\(.slug):\(.stock_qty)"] | join(" "))"'
curl -s https://api.cherryservers.com/v1/plans/<plan>/images | jq -r '.[].slug'
```

Remove `and (.specs.cpus.name | test("EPYC"))` to see every plan when picking the
helper. Teams, projects and SSH keys need your API key:

```bash
curl -s -H "Authorization: Bearer $CHERRY_SERVERS_API_KEY" https://api.cherryservers.com/v1/teams | jq '.[] | {id, name}'
curl -s -H "Authorization: Bearer $CHERRY_SERVERS_API_KEY" https://api.cherryservers.com/v1/teams/<team-id>/projects | jq '.[] | {id, name}'
curl -s -H "Authorization: Bearer $CHERRY_SERVERS_API_KEY" https://api.cherryservers.com/v1/ssh-keys | jq '.[] | {id, label, fingerprint}'
```

### Ordering in the portal instead

Order both servers together in one region and project, so they share a switch,
without user data. Copy the provider values into the rig file by hand, using the
table below, then continue from step 6.

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
| `node_parent_mac`, `node_bond_ports` (name and MAC of each member) | `ip link` and `/proc/net/bonding/bond0` on the node's original OS. Use permanent MACs. Both members must be in `/sys/class/net/bond0/bonding/slaves`; if one is missing, see [troubleshooting](troubleshooting.md#installation). |
| `node_external_if`, `node_external_mac` | The node's separate public NIC, if it has one; otherwise leave empty. |
| `vlan_vid_override` | `rig_values`, checked against the node's original network config (step 8 above). It is the tag on the wire, not a VLAN object ID. |
| `bastion_private_if`, `bastion_external_if` | `VLAN_IFACE` and `PUBLIC_IFACE` in the helper's `/etc/rig-network.env`. |
| `node_root_device` | A `/dev/disk/by-path/...` path on the node. Check the disk serial with `lsblk -o NAME,SERIAL,SIZE` first. |
| `bastion_ssh_user`, `raw_node_ssh_user`, `raw_node_ssh_key`, `bastion_ssh_key`, `private_link_known_hosts` | Your SSH access to both servers: `root` on Cherry's images, the key from the order, and their host keys pinned in the `known_hosts` file (step 9 above). |

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
