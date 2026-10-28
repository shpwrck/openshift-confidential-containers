# Quickstart: install OpenShift and CoCo on a new rig

This guide takes two freshly allocated servers to a single-node OpenShift
cluster with the confidential-container Operators installed. It is written for
a **disposable test rig**: step 5 erases the AMD node's disk. For an existing
customer cluster, read [customer planning](customer-planning.md) instead.

The steps are:

1. [Set up the controller](#1-set-up-the-controller)
2. [Write the rig file](#2-write-the-rig-file)
3. [Prepare the helper](#3-prepare-the-helper)
4. [Build boot files and check the private network](#4-build-boot-files-and-check-the-private-network)
5. [Install OpenShift](#5-install-openshift)
6. [Install the CoCo Operators](#6-install-the-coco-operators)

Then continue with [Trustee setup](trustee.md) and the
[capability tests](capability-status.md).

## Before you start

- [ ] You have two servers on one private VLAN: the AMD node and a helper whose
      bootstrap set up the mirror registry. After step 1, order both with
      [Cherry Servers setup](cherry-servers.md#order-the-servers), which also starts
      your rig file.
- [ ] The node's BIOS is configured and SEV-SNP works on the provider's original OS.
      Follow [firmware preflight](amd-firmware-preflight.md).
- [ ] The node's private VLAN interface is configured in its original OS, and from
      the node you can reach the helper's registry (HTTPS), DNS and NTP.
- [ ] You have a Red Hat pull secret and an SSH key pair for the node.

## 1. Set up the controller

Use a Linux machine with Bash, Python 3.12+, `jq`, SSH and Ansible. Run every
command from the root of this checkout.

```bash
umask 077
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
mkdir -p "$COCO_STATE_DIR"
python3 -m venv "$COCO_STATE_DIR/controller-venv"
source "$COCO_STATE_DIR/controller-venv/bin/activate"
python3 -m pip install -r requirements-dev.txt
make preflight
make fetch-cli-tools
export PATH="$COCO_STATE_DIR/bin:$PATH"
```

`make preflight` checks that the release files in this repository agree with
each other and that every image and tool is pinned to a digest. It does not
contact any registry or test hardware. `make fetch-cli-tools` downloads `oc` and
`openshift-install` for the pinned OpenShift version and checks their hashes.

To move to newer product versions, follow [release resolution](release-resolution.md) first.

### Coming back in a new terminal

Exports last only as long as the terminal that set them. In a new terminal, run
these from the checkout before any other command in this guide or the
[Cherry Servers setup](cherry-servers.md); the install lines above need no repeat:

```bash
umask 077
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
source "$COCO_STATE_DIR/controller-venv/bin/activate"
export PATH="$COCO_STATE_DIR/bin:$PATH"
```

Then set the provider API key. Run this line on its own: it waits silently for the
key, so pasted together with other lines it reads the next line instead. The length
it prints is `0` when nothing was read.

```bash
read -rs CHERRY_SERVERS_API_KEY && export CHERRY_SERVERS_API_KEY
echo "${#CHERRY_SERVERS_API_KEY}"
```

For Terraform, also export `CHERRY_API_KEY` and `TF_DATA_DIR` as in
[Order the servers](cherry-servers.md#order-the-servers). After step 6, export
`KUBECONFIG` and the context variables again and reopen the SSH tunnel to the API.

## 2. Write the rig file

All site-specific values go in one file outside the checkout:

If you ordered with Terraform, [Cherry Servers setup](cherry-servers.md#order-the-servers)
already created the file and appended the values Cherry assigned. Otherwise:

```bash
cp ansible/rig.example.yml "$COCO_STATE_DIR/rig.yml"
```

Edit `$COCO_STATE_DIR/rig.yml` and replace every `REPLACE_...` value. The file's
comments say where each one comes from. In short:

| Group | Values |
|---|---|
| Helper access | SSH user and key, private and public interface names (public IP from Terraform) |
| Node identity | SSH user and key for the original OS; a `known_hosts` file that pins both servers (server ID, hostname and project from Terraform) |
| Node network | Bond and member NIC names and permanent MACs (private addresses and VLAN tag from Terraform) |
| Install disk | A stable `/dev/disk/by-path/...` path whose serial you have checked |
| Credentials | Paths to the pull secret and node public key; a fresh `boot_artifacts_token` |

Defaults for everything else (cluster name, DNS names) are in
[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml). Its private addresses
do not apply on Cherry, which assigns them; Terraform supplies the real ones.

Export the provider API key without writing it to your shell history, for example
with this line, run on its own (it waits silently for the key):

```bash
read -rs CHERRY_SERVERS_API_KEY && export CHERRY_SERVERS_API_KEY
```

## 3. Prepare the helper

```bash
bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
```

This installs the pinned tools on the helper, mirrors the release images into
its registry, and configures private DNS and NTP for the node. It does not touch
the AMD node. The mirror step is slow on the first run; later runs reuse the
results as long as the inputs have not changed.

## 4. Build boot files and check the private network

Read the node's network identity, render the installer configuration and build
the boot files. Then check from the node's original OS that it can reach the
helper's registry, DNS and NTP over the private VLAN:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags discover,render,pxe -e install_mode=fresh \
  -e "@$COCO_STATE_DIR/rig.yml"
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/qualify-private-link.yml -e "@$COCO_STATE_DIR/rig.yml"
```

Neither command changes the node. Discovery reads it through the Cherry API and
the pinned SSH, and replaces any `discovery/node-macs.json` left in
`COCO_STATE_DIR` by an earlier rig. If the check fails, fix the node's network in
its original OS before continuing; [troubleshooting](troubleshooting.md#installation)
lists the usual causes.

## 5. Install OpenShift

> [!WARNING]
> This step **erases the AMD node** and installs OpenShift on it.

```bash
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

`fresh-install` stops at a BIOS checkpoint and asks you to type **SNP-SET** once
the firmware checks have passed. It then checks the node's hardware identity and
private network again, asks the provider to reinstall the node from the helper's
boot files, and waits for the installation. When it finishes it checks the
OpenShift version and health, applies the mirror configuration and stops serving
the boot files. `verify` repeats the version and health checks without
reinstalling anything.

The install also publishes the OpenShift web console through the helper's public
address, at `https://console-openshift-console.apps.sno-coco.<helper public IP>.sslip.io`.
Its certificate is self-signed. Log in as `kubeadmin`; the password is in
`/opt/install/cluster-assets/auth/kubeadmin-password` on the helper. To leave the
console private, add `-e public_console_enabled=false`. If the console step
fails, the run stops before it closes the boot files: close them with the
`pxe-stop` command in [troubleshooting](troubleshooting.md#installation), then
rerun the console step alone:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags public-console -e "@$COCO_STATE_DIR/rig.yml"
```

If the controller is interrupted after the provider has accepted the reinstall,
do not start over. Keep the same rig file and run:

```bash
bash ansible/up.sh --mode resume-install -e "@$COCO_STATE_DIR/rig.yml"
```

This finishes the existing installation without sending a second reinstall request.

## 6. Install the CoCo Operators

The cluster's kubeconfig is on the helper at
`/opt/install/cluster-assets/auth/kubeconfig`, and the API is only reachable on
the private VLAN. Copy the kubeconfig to `$COCO_STATE_DIR` and reach the API
through an SSH tunnel via the helper. Take the helper's login and the node's
private address from your rig file:

```bash
grep -E '^(bastion_ssh_user|bastion_ansible_host|node_vlan_ip):' "$COCO_STATE_DIR/rig.yml"
```

Put those values in the first two lines, then run the rest. The API name is
built from the default `cluster_name` and `base_domain` in
[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml):

```bash
HELPER='root@203.0.113.10'   # bastion_ssh_user@bastion_ansible_host
NODE_IP='10.0.0.7'           # node_vlan_ip
ssh "$HELPER" 'sudo cat /opt/install/cluster-assets/auth/kubeconfig' > "$COCO_STATE_DIR/kubeconfig"
ssh -f -N -L 6443:"$NODE_IP":6443 "$HELPER"
echo '127.0.0.1 api.sno-coco.coco.lab.local' | sudo tee -a /etc/hosts
```

Then name the context so every command targets this cluster on purpose:

```bash
export KUBECONFIG="$COCO_STATE_DIR/kubeconfig"
oc config rename-context admin validation
oc --context=validation get nodes
```

The test rig runs Trustee on the same cluster as the workloads, so both contexts
point at the same cluster:

```bash
export WORKER_CONTEXT=validation TRUSTEE_CONTEXT=validation
export TRUSTEE_LAB=1 INSTALL_TOPOLOGY=sno
make validate-sno-baseline
make install-coco-operators
```

The first run stops at each pending InstallPlan (all Subscriptions use Manual
approval). Check that the plans list the versions in the
[release manifest](../install/release-manifest.json), then approve them:

```bash
APPROVE_INSTALLPLANS=1 make install-coco-operators
```

The installer approves only plans that match the manifest. It waits for Node
Feature Discovery to label the node, for the Kata runtime to roll out (the node
reboots), and for the `kata-cc` RuntimeClass to use the `kata-snp` handler.

## Next steps

1. [Set up Trustee](trustee.md): collect the node's VCEK certificate, calculate the
   approved reference values, bind initdata and publish the resource policy.
2. [Configure guest image pulls](guest-images.md).
3. [Run the capability tests](capability-status.md). A healthy cluster alone
   does not show that the confidential-container controls work; the tests do.
