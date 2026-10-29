# Quickstart: install OpenShift and CoCo on a new rig

This guide orders two Cherry Servers machines and turns them into a single-node
OpenShift cluster with the confidential-container Operators installed. It is
written for a **disposable test rig**: step 4 erases the AMD node's disk. For an
existing customer cluster, read [customer planning](customer-planning.md) instead.

The steps are:

1. [Set up the controller](#1-set-up-the-controller)
2. [Order the rig](#2-order-the-rig)
3. [Set the BIOS](#3-set-the-bios)
4. [Install OpenShift](#4-install-openshift)
5. [Install the CoCo Operators](#5-install-the-coco-operators)

Then continue with [Trustee setup](trustee.md#disposable-lab) and the
[capability tests](capability-status.md).

## Before you start

- [ ] A Linux machine to run everything from (the controller), with Bash, Python
      3.12 or later, `curl`, `jq`, `make`, OpenSSH,
      [Terraform](https://developer.hashicorp.com/terraform/install) 1.9 or later
      and, for the Trustee step, [Podman](https://podman.io/).
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
or the release change, and load the cluster settings once step 5 has written them.

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

Delivery usually takes 15 to 30 minutes and sometimes over an hour. If it stops,
fix what it reports and run it again: it skips the stages that are done, and
takes over a server that Cherry was still delivering instead of ordering
another. [Cherry Servers setup](cherry-servers.md) explains what it chooses and
how to order something else.

> [!IMPORTANT]
> Step 4 erases the disk that `node_root_device` in the rig file names. It is the
> disk that holds the original OS's `/boot/efi`, and the file's comments show its
> serial and the other disks. To install on another disk, change that line.
> Step 4 shows the disk again before it asks to erase it.

## 3. Set the BIOS

A new node's BIOS usually has SEV-SNP switched off. Set it through the node's
browser console, as [Set the BIOS](cherry-servers.md#set-the-bios) shows. You can
do this while `make order-rig` waits for the mirror; it says when.

Step 4 checks SEV-SNP on the node before it changes anything. To check right
after the BIOS change, without starting the install:

```bash
make check-node-snp
```

It runs the [host check](amd-firmware-preflight.md#prove-the-running-host) over
the pinned SSH connection and prints the board, BIOS version, boot mode and
install disk, with a `PASS` or `FAIL` line for each check. The output is saved
in `$COCO_STATE_DIR/evidence`.

To save time when `make order-rig` has finished and you are still in the BIOS,
start the helper's preparation in another terminal with `bash ansible/up.sh`.
It does not touch the node. Let it finish before step 4, which then reuses what
it prepared.

## 4. Install OpenShift

> [!WARNING]
> This step **erases the AMD node's install disk** and installs OpenShift on it.

```bash
bash ansible/up.sh --mode fresh-install
```

It reads the rig file that `make order-rig` wrote. First it checks the node over
the pinned SSH connection: that it is the server Cherry reports, that it booted
in UEFI mode, that it passes the
[SEV-SNP host check](amd-firmware-preflight.md#prove-the-running-host), and that
the install disk exists. It saves that output in `$COCO_STATE_DIR/evidence`,
shows the install disk with its serial, and asks you to type the node's server
ID. Nothing has changed up to that point, and nothing more is asked after it, so
you can leave it running. It then:

1. Prepares the helper: installs the pinned tools, mirrors the release images
   into its registry, and configures private DNS and NTP for the node. This is
   the slow part of a first run; a rerun reuses the results while the inputs are
   unchanged.
2. Reads the node's network identity, renders the installer configuration and
   builds the boot files.
3. Checks from the node's original OS that it reaches the helper's registry, DNS
   and NTP over the private VLAN. If it does not, the run stops before erasing
   anything; [troubleshooting](troubleshooting.md#installation) lists the usual
   causes.
4. Asks Cherry to reinstall the node from the helper's boot files and waits for
   the installation, 45 to 70 minutes on the tested rigs. To follow it, run
   `sudo tail -f /opt/install/cluster-assets/.openshift_install.log` on the helper.
5. Checks the OpenShift version and health, applies the mirror configuration and
   stops serving the boot files.

To answer the question ahead, for a run without a terminal, add
`-e confirm_erase=<server ID>`. The checks still run, and any failure still stops
it. To repeat the version and health checks later without reinstalling anything,
run `bash ansible/up.sh --mode verify`.

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
bash ansible/up.sh --mode resume-install
```

This finishes the existing installation without sending a second reinstall request.

## 5. Install the CoCo Operators

```bash
make connect
source scripts/env.sh
make install-coco-operators
```

The cluster API is only reachable on the private VLAN. `make connect` copies the
cluster's kubeconfig from the helper to `$COCO_STATE_DIR/kubeconfig`, names its
context `validation` and opens an SSH tunnel to the API through the helper. It
then writes `$COCO_STATE_DIR/lab.env`, shows the node and waits, up to 15
minutes, while a new install settles. The test rig runs Trustee on the same
cluster as the workloads, so `lab.env` points both `WORKER_CONTEXT` and
`TRUSTEE_CONTEXT` at `validation`. `source scripts/env.sh` loads it, here and in
every new terminal.

The tunnel keeps running after the terminal closes. If `oc` cannot reach the
cluster later, for example after the controller restarts, run `make connect`
again.

`make install-coco-operators` creates the Subscriptions with Manual approval and
waits until each one has its InstallPlan. It checks every plan against the
[release manifest](../install/release-manifest.json), shows the plans in one
table and asks you to type `yes`. Without a terminal, approve them ahead with
`APPROVE_INSTALLPLANS=1 make install-coco-operators`; plans that do not match the
manifest are refused either way. Then it waits for Node Feature Discovery to
label the node, for the Kata runtime to roll out (the node reboots, and the API
stops answering for a few minutes) and for the `kata-cc` RuntimeClass to use the
`kata-snp` handler. It takes about 20 minutes, most of it the rollout and the reboot.

## Next steps

1. [Set up Trustee](trustee.md): collect the node's VCEK certificate, calculate the
   approved reference values, bind initdata and publish the resource policy.
2. [Configure guest image pulls](guest-images.md).
3. [Run the capability tests](capability-status.md). A healthy cluster alone
   does not show that the confidential-container controls work; the tests do.
