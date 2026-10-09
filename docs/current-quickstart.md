# Quickstart

This is the fresh-install path for a **disposable AMD single-node OpenShift rig**.
It targets the [validated release set](validation/README.md). The previous rig is
retired; allocate and qualify new hardware before using these commands.
For an existing customer cluster, use [customer planning](design/customer-scoping.md).

## Prepare the controller

Use Linux with Bash, Python 3.12+, `jq`, SSH and Ansible. Run commands from the checkout root.

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

`make preflight` checks recorded identities and agreement between repository files.
It does not contact registries, establish a supported upgrade path or test hardware.
Use [release resolution](release-resolution.md) when selecting new versions.

## Supply the rig inputs

Keep secrets and generated state outside both the checkout and Homelab, including
Git-ignored files. Put environment values in `$COCO_STATE_DIR/rig.yml`; use
[the Ansible defaults](../ansible/group_vars/all.yml) as the field reference.

| Input | Required values |
|---|---|
| Ownership and access | Provider, current server/project/hostname, helper SSH target/user/key, pinned host keys |
| Network | Private addresses/subnet, VLAN wire tag, actual NIC names/MACs, DNS/NTP and mirror hostname |
| Installation | Verified disk serial and stable `/dev/disk/by-path/` path, cluster name/domain, node public SSH key |
| Credentials | External `pull_secret_src` and `node_ssh_pubkey_src` paths; fresh private `boot_artifacts_token` |

[Cherry setup](cherry-validation.md) covers its supplied-rig inputs and manual
provisioning/BIOS prerequisites. Allocate the servers separately; the wrapper
operates on supplied infrastructure.

## Prepare and install

First complete [firmware preflight](amd-firmware-preflight.md). While the raw
provider OS is still running, configure the intended private link and prove that
the node reaches the helper's registry, DNS and NTP. A helper readiness marker or
provider VLAN assignment alone does not prove this path.

```bash
bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
```

Prepare verifies tools, mirror content and private services. Changed inputs invalidate
completion markers; unchanged inputs reuse the artifacts. Build boot files and run
the standalone private-link check using [the Cherry sequence](cherry-validation.md#install).
Then install explicitly:

```bash
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

Fresh install **replaces the selected node's OS**. It checks hardware identity and
the private link before submitting a journaled rebuild. Completion verifies the
actual OCP version/digest and health, applies mirror resources and closes boot publication.
`verify` checks the installed platform without submitting a rebuild.

If the controller stops after the provider accepts the request, retain the same
inputs, assets and accepted journal, then run:

```bash
bash ansible/up.sh --mode resume-install -e "@$COCO_STATE_DIR/rig.yml"
```

Resume sends no new rebuild and does not reconnect to the replaced provider OS.
An ambiguous request requires provider-state inspection before a deliberate retry.
See [troubleshooting](troubleshooting.md) for publication cleanup and recovery.

## Install CoCo and Trustee

Load the new cluster's protected kubeconfig and confirm the context identifies the
intended rig. Select it explicitly; `validation` below is an example context name.
For the co-located disposable SNO lab:

```bash
export WORKER_CONTEXT=validation TRUSTEE_CONTEXT=validation
export TRUSTEE_LAB=1 INSTALL_TOPOLOGY=sno
make validate-sno-baseline
make install-coco-operators
```

The installer stops at pending Manual InstallPlans. Inspect the selected plans,
then rerun with `APPROVE_INSTALLPLANS=1` to approve only matching inventory entries.
It waits for NFD, the scoped Kata rollout and `kata-cc` with handler `kata-snp`.

Collect fresh worker collateral and follow [Trustee setup](trustee-current.md) to
bootstrap, calculate approved launch/TCB references, bind initdata and configure
resource release. The lab's Permissive profile must be selected explicitly and
still needs an enforcing resource policy for the initdata/RVPS tests.

Finally run [the capability tests](capability-status.md). Each proof requires a
working control, the intended denial and successful restoration/recovery. Record
host, ordinary-pod and guest isolation separately. A healthy platform alone does
not establish confidential-container acceptance.
