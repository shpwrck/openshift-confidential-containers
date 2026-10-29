# Cherry Servers setup

The [validation runs](validation.md) used Cherry Servers. `make order-rig`
([quickstart step 2](quickstart.md#2-order-the-rig)) orders the two servers and
writes the rig file. This page explains what it chooses, how to set the node's
BIOS through the Cherry console, and how to order differently.

A few Cherry Servers terms first. A **team** is the billing account. A **project**
inside it holds servers and gives the servers in each region a shared private VLAN.
A **region** is a data center. A **plan** is a hardware model, and an **image** is the
operating system Cherry installs on delivery. Plans are ordered from stock, so a plan
can be listed in a region with none available.

## What `make order-rig` chooses

| Choice | What it does |
|---|---|
| Plans and region | [`infra/cherry/tested-plans.json`](../infra/cherry/tested-plans.json) lists the plans that completed a full run. It offers every region where a tested node plan is in stock, paired with the cheapest tested helper there, and lists fully tested pairs first, then by price. Without a tested helper in stock, it offers the cheapest bare-metal plan with AlmaLinux 9 and at least 400 GB of disk, marked untested. Both servers go in one region so they share its private VLAN. |
| Images | Ubuntu 26.04 on the node, the first image whose kernel (7.0) showed SNP host support; OpenShift later replaces it. AlmaLinux 9 on the helper: Cherry offers no RHEL image, Red Hat supports RHEL for the mirror registry, and AlmaLinux 9 is a compatibility test. |
| Project | The one you pick. Use a project with nothing else in it, so the private VLAN holds only these two servers. |
| SSH key | The key you name, for `root` on both servers. If your Cherry account already has it, the order uses it by ID; otherwise Terraform adds it. A key with a passphrase must be loaded in `ssh-agent` first. |
| Install disk | The node disk that holds the original OS's `/boot/efi`, or else the first NVMe disk. The rig file lists the others; change `node_root_device` to use one of them. |

`make cherry-plans` shows the offer, with hourly prices in euros, without ordering
anything.

Terraform waits up to three hours for Cherry to deliver each server. If it stops
waiting first, or you interrupt `make order-rig`, a server Cherry is still
delivering is missing from the Terraform state. Run `make order-rig` again: it
finds that server by its hostname, plan and region, waits for it and imports it
into the state, so nothing is ordered twice. It does not take over a server whose
delivery failed; delete that one in the portal first.

Cherry VLANs do not span switches. If the two servers land on different switches,
`make order-rig` stops and, when you run it again, offers to replace the helper,
or you can ask Cherry support to move it. Terraform never reinstalls the node
after ordering: Ansible rebuilds it into OpenShift through the Cherry API, and the
configuration ignores that drift.

### When no tested node plan is in stock

`make cherry-plans ARGS=--untested` lists the untested bare-metal plans whose CPU
supports SEV-SNP (an EPYC 7003, 8004, 9004 or 9005 series), and
`make order-rig ARGS=--untested` orders one. The CPU is not enough: the board and
its BIOS must expose SEV-SNP too. A prior H12SSW-NTR/EPYC 7313P allocation failed
to reserve the RMP table despite saved SNP settings. `make check-node-snp` in
[quickstart step 3](quickstart.md#3-set-the-bios) tells you before anything is
installed. After a plan passes a full run, add it to `tested-plans.json`.

### Answering ahead

Each question has a flag, for a run without a terminal or to repeat a choice:

```bash
make order-rig ARGS='--region US-Chicago --project 123456 --ssh-key ~/.ssh/id_ed25519 --pull-secret ~/pull-secret.json --confirm-order'
```

`--confirm-order` orders without asking, so it starts billing. `--reboot-node`,
`--replace-helper` and `--restart-bootstrap` answer the questions that come up only
when something goes wrong. `python3 scripts/order-rig.py --help` lists them all.

### What it keeps in `COCO_STATE_DIR`

| File | Contents |
|---|---|
| `cherry-api-key` | Your API key, saved by `source scripts/env.sh` |
| `rig-order.json` | Your answers: plans, prices, project, SSH key |
| `cherry.tfvars`, `cherry.tfstate`, `terraform/` | Terraform's variables, state and provider cache |
| `known_hosts`, `known_hosts.servers` | Both servers' SSH host keys, pinned on first contact, and the server IDs they belong to. Keys of an earlier rig are moved aside, because Cherry reuses addresses. |
| `credentials/pull-secret.json` | A copy of your pull secret |
| `helper-bootstrap.sh` | The mirror bootstrap it ran on the helper |
| `rig.yml` | The rig file |
| `evidence/` | The output of each `make check-node-snp`, and of the node checks the install runs |

## Set the BIOS

A newly delivered node's BIOS usually has SEV-SNP switched off. Set it through the
node's browser console, which the board's management controller (BMC) provides:

1. In the [Cherry portal](https://portal.cherryservers.com/), open the node's server
   page and choose **Console**.
2. Enter your own public IP address, so the console accepts it, and choose
   **Connect to console**.
3. Log in to the BMC as `kuser`. The portal shows the console password for 24 hours
   after delivery; after that, reset it from the server page with
   **Actions > Reset console password**.
4. On the tested Supermicro boards, open **Remote Control** and launch the
   **HTML5** console.
5. Reboot the node, from the BMC's power control or with `reboot` over SSH, and press
   **Del** at the Supermicro logo to enter the BIOS setup.
6. Set the values below, then save and reboot (**F4** on Supermicro).
7. When the original OS is back, run `make check-node-snp`.

The tested H13SST-G boards (EPYC 9124 and 9254, BIOS 3.7) used these settings,
under Advanced > CPU/NB Configuration:

| Setting | Value |
|---|---|
| SVM / SEV | Enabled (already set on delivery) |
| SMEE | Enabled |
| SNP Memory / RMP Table Coverage | Enabled, covering all system memory |
| SEV-ES ASID Space Limit | 100 |
| IOMMU | Enabled |
| SEV-SNP Support | Enabled |

Other boards name and place these controls differently; read
[firmware preflight](amd-firmware-preflight.md) before changing an untested one.
The settings survived the later reboots on the tested boards, including the Kata
rollout. Check them again after each reinstall or firmware change.

## Ordering by hand

Use this path to order in the portal, or to see what `make order-rig` does.

1. Order both servers together in one region and project, so they share a switch,
   with the order's SSH key and **without user data**. Cherry puts both on the
   project's private VLAN and configures it in their original OS as a tagged child
   of the uplink (for example `bond0.2738`), and installs the order's SSH key for
   `root`. It does neither for a server ordered with cloud-init user data.
2. Pin both host keys in a `known_hosts` file outside the checkout, for example by
   logging in once with `-o UserKnownHostsFile="$COCO_STATE_DIR/known_hosts"`.
   Ansible reads only the file `private_link_known_hosts` names and refuses any
   host missing from it.
3. Start the helper's mirror bootstrap. It runs as a systemd unit, as cloud-init
   would, so it keeps going after SSH disconnects. It holds no secrets: the registry
   password is generated on the helper. The archive it installs is pinned in the
   [release manifest](../install/release-manifest.json) (`tools.mirrorRegistry`).

   ```bash
   python3 scripts/render-helper-bootstrap.py > "$COCO_STATE_DIR/helper-bootstrap.sh"
   ssh root@<helper-public-ip> \
     'install -m 700 /dev/stdin /usr/local/sbin/helper-bootstrap.sh && systemd-run --unit=helper-bootstrap /usr/local/sbin/helper-bootstrap.sh' \
     < "$COCO_STATE_DIR/helper-bootstrap.sh"
   ```

   `/opt/mirror/MIRROR_READY` on the helper means the registry is serving;
   `/opt/mirror/MIRROR_FAILED` means a step failed, and
   `/var/log/mirror-bootstrap.log` says which. Run the renderer with `--help` to
   change the registry name or paths, to give an explicit VLAN tag and address
   instead of adopting Cherry's, or to print cloud-init user data for a provider
   that keeps its own setup with it.
4. Copy [`ansible/rig.example.yml`](../ansible/rig.example.yml) to
   `$COCO_STATE_DIR/rig.yml` and fill it in from the table below.

### Where each rig-file value comes from

Read every value from the servers you were given, not from an old rig.

| Rig-file key | Where to read it |
|---|---|
| `node_server_id`, `node_provider_hostname`, `node_provider_project_id` | The node in the Cherry portal or API. The automation checks them against the API before reinstalling. |
| `bastion_ansible_host`, `bastion_public_ipv4_override` | The helper's public IPv4. |
| `node_vlan_ip`, `bastion_vlan_ip`, `machine_network`, `vlan_cidr`, `vlan_prefix` | Each server's private IPv4 and its network. Cherry assigns these; the `group_vars` defaults do not apply on Cherry. |
| `vlan_vid_override` | The tag on the wire: the number after `802.1Q id` in `ip -d link show type vlan` on the node, which must match `VLAN_VID` in the helper's `/etc/rig-network.env`. It is not a VLAN object ID. |
| `node_parent_mac`, `node_bond_ports` (name and MAC of each member) | `ip -d link` on the node's original OS. Use permanent MACs (`permaddr`). Both members must be in `/sys/class/net/bond0/bonding/slaves`; if one is missing, see [troubleshooting](troubleshooting.md#installation). |
| `node_external_if`, `node_external_mac` | Empty: the tested nodes have no separate public NIC. |
| `bastion_private_if`, `bastion_external_if` | `VLAN_IFACE` and `PUBLIC_IFACE` in the helper's `/etc/rig-network.env`. |
| `node_root_device` | A `/dev/disk/by-path/...` path on the node. Check the disk serial with `lsblk -o NAME,SERIAL,SIZE` first. |
| `bastion_ssh_user`, `raw_node_ssh_user`, `raw_node_ssh_key`, `bastion_ssh_key`, `private_link_known_hosts` | `root`, the private half of the order's key, and the `known_hosts` file from step 2. |

The tested network was an 802.3ad (LACP) bond of two physical NICs. The installed
bond has no public address; only its private VLAN interface gets one.

## Install

The trial delivered the first boot files to the node over the helper's public IP,
protected by a random token in the URL. Everything after that (the installer
environment, the installed node and the workloads) used only the private VLAN.
Booting entirely over the private network from power-on has not been tested.
Successful installation removes the public boot files;
[troubleshooting](troubleshooting.md) covers interrupted runs.

Each new allocation needs its own hardware checks, VCEK certificates, reference
values and isolation evidence. Do not reuse values from a retired rig.
