# Quickstart: install OpenShift and CoCo on a new rig

This guide orders two Cherry Servers machines and turns them into a single-node
OpenShift cluster with the confidential-container Operators installed. It is
written for a **disposable test rig**: step 6 erases the AMD node's disk. For an
existing customer cluster, read [customer planning](customer-planning.md) instead.

The steps are:

1. [Set up the controller](#1-set-up-the-controller)
2. [Order the rig](#2-order-the-rig)
3. [Set the BIOS](#3-set-the-bios)
4. [Prepare the helper](#4-prepare-the-helper)
5. [Build boot files and check the private network](#5-build-boot-files-and-check-the-private-network)
6. [Install OpenShift](#6-install-openshift)
7. [Install the CoCo Operators](#7-install-the-coco-operators)

Then continue with [Trustee setup](trustee.md) and the
[capability tests](capability-status.md).

## Before you start

- [ ] A Linux machine to run everything from (the controller), with Bash, Python
      3.12 or later, `curl`, `jq`, `make`, OpenSSH and
      [Terraform](https://developer.hashicorp.com/terraform/install) 1.9 or later.
- [ ] A [Cherry Servers](https://portal.cherryservers.com/) account with an empty
      project and an [API key](https://portal.cherryservers.com/settings/api-keys).
      The tested rig costs about 1.25 EUR per hour until you
      [retire it](maintenance.md#retire-the-infrastructure).
- [ ] An SSH key pair for both servers.
- [ ] Your Red Hat [pull secret](https://console.redhat.com/openshift/install/pull-secret),
      saved as a file.

## 1. Set up the controller

From the root of this checkout, in every new terminal:

```bash
source scripts/env.sh
```

The first time, this builds the controller in `COCO_STATE_DIR`, outside the
checkout (by default `~/.local/state/openshift-confidential-containers`): a
Python environment with the pinned requirements, and `oc` and
`openshift-install` for the pinned OpenShift version, checked against their
published hashes. It also checks that the release files in this repository agree
and pin every image and tool to a digest; this contacts no registry or hardware.
Then it asks once for your Cherry Servers API key, checks it, and keeps it in
`$COCO_STATE_DIR/cherry-api-key`, readable only by you.

Later runs take a second. They rebuild the controller only when the requirements
or the release change, and load the cluster settings once step 7 has written them.

To move to newer product versions, follow [release resolution](release-resolution.md) first.

## 2. Order the rig

```bash
make order-rig
```

It asks its questions first: which rig to order (the tested plans in stock,
cheapest first, with their hourly price), which project, which SSH key and where
your pull secret is. It orders nothing until you type `yes`. Then it runs on its
own, mostly waiting for Cherry to deliver the servers:

- It orders the AMD node and the helper with the [Terraform in `infra/cherry`](../infra/cherry/).
- It pins both servers' SSH host keys in `$COCO_STATE_DIR/known_hosts` the first
  time it reaches them; the later node and network checks use that file.
- It starts the helper's mirror registry bootstrap.
- It checks the node's private VLAN, its network bond and its disks. A new node
  sometimes boots with one bond member missing; it offers the one reboot that fixes it.
- It waits for the mirror registry, then writes `$COCO_STATE_DIR/rig.yml`, the
  file every later step reads.

If it stops, fix what it reports and run it again: it skips the stages that are
done. [Cherry Servers setup](cherry-servers.md) explains what it chooses and how
to order something else.

> [!IMPORTANT]
> Step 6 erases the disk that `node_root_device` in the rig file names. It is the
> disk that holds the original OS's `/boot/efi`, and the file's comments show its
> serial and the other disks. To install on another disk, change that line.

## 3. Set the BIOS

A new node's BIOS usually has SEV-SNP switched off. Set it through the node's
browser console, as [Set the BIOS](cherry-servers.md#set-the-bios) shows. You can
do this while `make order-rig` waits for the mirror; it says when.

When the node's original OS is back up, check that SEV-SNP works:

```bash
make check-node-snp
```

It prints the board and BIOS version, checks that the node booted in UEFI mode,
and runs the [host check](amd-firmware-preflight.md#prove-the-running-host) over
the pinned SSH connection. The output is also saved in `$COCO_STATE_DIR/evidence`.
Continue only when it reports `RESULT: SEV-SNP host prerequisites passed`.

## 4. Prepare the helper

```bash
bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
```

This installs the pinned tools on the helper, mirrors the release images into
its registry, and configures private DNS and NTP for the node. It does not touch
the AMD node. The mirror step is slow on the first run; later runs reuse the
results as long as the inputs have not changed.

## 5. Build boot files and check the private network

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

## 6. Install OpenShift

> [!WARNING]
> This step **erases the AMD node** and installs OpenShift on it.

```bash
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

`fresh-install` stops at a BIOS checkpoint and asks you to type **SNP-SET**: do so
once `make check-node-snp` from step 3 has passed. It then checks the node's hardware identity and
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

## 7. Install the CoCo Operators

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
point at the same cluster. Save these settings in `lab.env`, which
`source scripts/env.sh` loads in every new terminal:

```bash
cat > "$COCO_STATE_DIR/lab.env" <<EOF
export KUBECONFIG="$COCO_STATE_DIR/kubeconfig"
export WORKER_CONTEXT=validation TRUSTEE_CONTEXT=validation
export TRUSTEE_LAB=1 INSTALL_TOPOLOGY=sno
EOF
source "$COCO_STATE_DIR/lab.env"
make validate-sno-baseline
make install-coco-operators
```

The tunnel keeps running after its terminal closes. If `oc --context=validation get nodes`
can't connect later, open it again with the `ssh -f -N -L` line above.

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
