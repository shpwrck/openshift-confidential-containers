# Quickstart: install OpenShift and CoCo on a new rig

This guide takes two freshly allocated servers to a single-node OpenShift
cluster with the confidential-container Operators installed. It is written for
a **disposable test rig**: step 5 erases the AMD node's disk. For an existing
customer cluster, read [customer planning](design/customer-scoping.md) instead.

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

- [ ] You have two servers on one private VLAN: the AMD node and a helper.
      [Cherry Servers setup](cherry-servers.md) lists what the trial used.
- [ ] The helper runs the mirror registry. The
      [cloud-init template](../ansible/bootstrap/mirror-registry.yaml.j2) sets it up.
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

## 2. Write the rig file

All site-specific values go in one file outside the checkout:

```bash
cp ansible/rig.example.yml "$COCO_STATE_DIR/rig.yml"
```

Edit `$COCO_STATE_DIR/rig.yml` and replace every `REPLACE_...` value. The file's
comments say where each one comes from. In short:

| Group | Values |
|---|---|
| Helper access | Public IP, SSH user and key, private and public interface names |
| Node identity | Provider server ID, hostname and project ID; SSH user and key for the original OS; a `known_hosts` file that pins both servers |
| Node network | Bond and member NIC names and permanent MACs, the VLAN tag on the wire |
| Install disk | A stable `/dev/disk/by-path/...` path whose serial you have checked |
| Credentials | Paths to the pull secret and node public key; a fresh `boot_artifacts_token` |

Defaults for everything else (cluster name, private addresses, DNS names) are in
[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml).

Export the provider API key without writing it to your shell history, for example:

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

Render the installer configuration, build the boot files, then check from the
node's original OS that it can reach the helper's registry, DNS and NTP over the
private VLAN:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags render,pxe -e install_mode=fresh \
  -e "@$COCO_STATE_DIR/rig.yml"
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/qualify-private-link.yml -e "@$COCO_STATE_DIR/rig.yml"
```

The check does not change either server. If it fails, fix the node's network in
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

If the controller is interrupted after the provider has accepted the reinstall,
do not start over. Keep the same rig file and run:

```bash
bash ansible/up.sh --mode resume-install -e "@$COCO_STATE_DIR/rig.yml"
```

This finishes the existing installation without sending a second reinstall request.

## 6. Install the CoCo Operators

The cluster's kubeconfig is on the helper at
`/opt/install/cluster-assets/auth/kubeconfig`, and the API is only reachable on
the private VLAN. Copy the kubeconfig to `$COCO_STATE_DIR` and give the
controller a route to the API (for example, an SSH tunnel through the helper).
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
