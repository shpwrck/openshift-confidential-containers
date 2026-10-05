# Current quickstart

This checkout targets **OCP 4.20.39, OSC 1.13, and Trustee 1.2** for CPU confidential containers. The OCP payload and authenticated catalog, bundle, related-image, and helper-image identities are verified. See [the resolution procedure and evidence](release-resolution.md) before refreshing these pins. The new workflow has local fixture coverage but has **not completed a new Latitude hardware run**. Historical OCP 4.20.18 results do not validate this release set.

The authoritative inputs are [the release manifest](../install/release-manifest.json). Start here instead of copying commands with older pins from historical runbooks. See [Latitude validation](latitude-validation.md) for infrastructure planning and the acceptance record.

## Choose the operation

| Need | Entry point | Behavior |
|---|---|---|
| Check repository consistency | `python3 scripts/verify-release.py` | Local checks; does not establish deployment readiness. |
| Check deployment inputs | `python3 scripts/verify-release.py --require-resolved` | Fails while any required artifact identity remains unresolved. |
| Prepare a supplied bastion | `bash ansible/up.sh --mode prepare` | Mirror/tools/DNS preparation; the default mode. |
| Plan disposable infrastructure | `bash ansible/up.sh --mode prepare --plan-tf` | Terraform init/plan only; no apply or Ansible work. |
| Fresh install on the disposable rig | `bash ansible/up.sh --mode fresh-install` | Explicit machine reinstall, health/version checks, endpoint closure. |
| Verify an installed cluster | `bash ansible/up.sh --mode verify` | Checks the selected OCP version, payload and health; no reinstall or Terraform. |

Prepare and fresh-install stop at the unresolved-release check before making changes. Resolve the recorded identities from the selected authenticated catalogs; do not mark entries verified merely to bypass this check. `--plan-tf` also requires resolved release inputs before infrastructure planning.

**Existing customer clusters need the separate upgrade procedure.** The provider reinstall path replaces the machine's installed OS. OCP 4.20.39 is a target, not a verified update edge from every 4.20.18 cluster. Preserve the customer's cluster ID, update graph, operator state, Trustee resources and storage before scheduling an upgrade. The [adjustment plan](design/current-version-adjustment-plan.md) records the migration work still needed.

## Prepare the controller

Use a Linux controller with Python 3.12+, the development requirements, Ansible, Terraform, and the required shell tools. Run commands from the checkout root unless a path is absolute. The wrapper also works from another working directory.

```bash
python3 -m venv "$HOME/.local/state/coco-dev-venv"
source "$HOME/.local/state/coco-dev-venv/bin/activate"
python3 -m pip install -r requirements-dev.txt
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
umask 077
mkdir -p "$COCO_STATE_DIR"
python3 scripts/verify-release.py
python3 scripts/verify-release.py --require-resolved
```

Keep pull secrets, private keys, kubeconfigs, Terraform state and proof evidence outside the checkout and outside Homelab. `COCO_STATE_DIR` is rejected when it resolves inside either location. The wrapper keeps Terraform state and provider data in separate `terraform/bastion` and `terraform/node` directories there. It refuses to provision when it finds in-checkout state, even if external state also exists. Reconcile the resource identities and preserve the authoritative state outside the checkout before continuing so existing servers are not duplicated; do not overwrite either state blindly.

An existing bastion can keep its remote pull secret. A new bastion can receive a controller file through `pull_secret_src`. Put environment-specific Ansible values in a private external YAML file, for example `$COCO_STATE_DIR/rig.yml`. Review [the defaults](../ansible/group_vars/all.yml) and set:

- Bastion SSH target/user/key and public IP, VLAN VID, selected server ID, NIC names and install disk.
- Cluster name/domain, network and mirror endpoint matching the selected environment.
- `pull_secret_src`: the absolute external Red Hat pull-secret path, if staging it from this controller.
- `node_ssh_pubkey_src`: the public key to embed in the node.
- `boot_artifacts_token`: a fresh value from `openssl rand -hex 16`, kept in that external file.

Select the installation disk explicitly. Prefer its verified `/dev/disk/by-path/` path for
`node_root_device` (or each machine's `root_device`), as recommended by the
[Agent-based Installer root-device guidance](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/observability/installing_an_on-premise_cluster_with_the_agent-based_installer/index).
The Miami validation node's OS disk changed from `nvme0n1` to `nvme1n1` after a firmware reboot.
Match the stable path to the intended disk serial and boot target before installation; do not
reuse a previous allocation's disk path.

Load the Latitude API credential through the environment (`LATITUDESH_AUTH_TOKEN`), without placing its value in shell history or checked-in files. No credentials are included in this checkout.

## Prepare, install, verify

Once release inputs are resolved and the external environment file is complete:

```bash
bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
# Continue only after the firmware/SNP and private-link checks pass:
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

These commands reuse infrastructure. `--apply-tf` explicitly adds Terraform provisioning; review [the infrastructure plan](latitude-validation.md) first. The wrapper reads non-secret bastion IP, VLAN VID and server ID outputs after apply and passes them to Ansible. Explicit Ansible overrides still win. Fresh installation retains the existing BIOS acknowledgement gate. Complete [AMD firmware preflight](amd-firmware-preflight.md) for the actual board, firmware security fixes, UEFI boot path and raw-host SNP result before continuing. Do not use `skip_bios_pause` as a substitute for that verification.

Before reinstalling, also complete the [private-link check](latitude-validation.md#prove-the-private-link-before-reinstall)
from the raw node. Apply VLAN assignments separately so the provider OS remains available for
these probes. A successful bastion mirror run or provider `connected` status cannot establish
that the node reaches the mirror, DNS and NTP. This is currently a manual prerequisite.

Tools are verified against the requested release's published checksums. Existing binaries are reused only when their recorded hashes match. A changed ImageSet, tool, destination or release invalidates the mirror completion marker. A changed installer, payload or rendered configuration invalidates PXE assets. Rebuilding assets belonging to an existing cluster requires deliberate `reinstall_existing=true` or a new assets directory; it is not an upgrade shortcut.

A provider request is recorded before submission. If a timeout leaves the request ambiguous, inspect provider state before using `retry_reinstall=true`. A successful request for unchanged boot inputs is not automatically sent again.

Provider request journals live outside generated assets (by default `/opt/install/provider-requests`) and survive PXE regeneration. A legacy journal inside the assets directory stops regeneration until its state is inspected and the record is moved to the durable directory.

PXE publication copies artifacts to `/var/www/coco-boot-artifacts`. The installer source and assets remain private under `/opt/install`; only the published copies need nginx access. Preparation verifies nginx readability and public HTTP Range behavior before a provider reinstall can proceed.

Successful fresh installation checks the actual ClusterVersion version and digest, applies the generated mirror resources, and closes the boot endpoint. If an install stops midway, inspect whether the node still needs the boot files; once it does not, close the endpoint explicitly:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags pxe-stop -e "@$COCO_STATE_DIR/rig.yml"
```

## Continue to confidential-container validation

A healthy OCP install is only the platform checkpoint. Install the resolved operator set, verify the selected runtime handler, collect target-hardware endorsement collateral, and configure Trustee using its generated resources. Trustee 1.2 ownership, TLS, policy and RVPS inputs require the updated flow; a historical standalone `KbsConfig` is not silently adopted.

Use the isolated proof runner only on the disposable validation environment. Record a working control, the intended denial, and successful recovery for every selected proof. A pod that merely fails to start is not evidence of policy enforcement. Encrypted images remain an explicit experiment; CPU validation does not establish GPU support. See [the validation acceptance record](latitude-validation.md#acceptance-evidence).
