# Ansible installation workflow

This tree prepares the mirror bastion and installs a **disposable AMD single-node OpenShift rig**. Start with the [current quickstart](../docs/current-quickstart.md) for controller requirements, external inputs and the selected release. [Latitude validation](../docs/latitude-validation.md) records what has actually passed. The earlier June/July hardware results apply to their historical releases.

## Responsibilities and phases

Terraform owns the two servers, VLAN, firewall and their assignments. Ansible owns bastion preparation, installer artifacts and the explicit provider reinstall request. The node's firmware must be checked on the actual machine before installation.

| Phase | Tags | Behavior |
|---|---|---|
| Bastion preparation | `bastion-prep` | Configure egress, verify tools, merge registry authentication, mirror selected images, verify DNS and NTP. |
| Firmware acknowledgement | `bios` | Require the [actual-board preflight](../docs/amd-firmware-preflight.md), UEFI boot path and successful SNP host check. |
| Node discovery | `discover` | Query exact server IDs, validate internal/public MAC identities and save bindings in external state. |
| Configuration | `render` | Merge validated MACs into current machine inputs; render private install and agent configuration files. |
| Boot artifacts | `pxe` | Generate input-bound PXE files, serve the tokenized endpoint and check HTTP Range behavior. |
| Installation | `drive` | In fresh mode, request the provider reinstall, wait for the cluster, verify its release and apply validated mirror resources. |
| Endpoint cleanup | `pxe-stop` | Remove the boot webroot and nginx configuration once the node no longer needs them. |

The `install` tag groups the destructive installation path. Use the wrapper modes below for normal operation. A firmware acknowledgement or a saved completion marker is not hardware proof.

## Run from the checkout root

Prepare a private `$COCO_STATE_DIR/rig.yml` using the [quickstart inputs](../docs/current-quickstart.md#prepare-the-controller). Keep the Latitude credential in `LATITUDESH_AUTH_TOKEN` and all secret-bearing files outside the checkout and Homelab. Use the same external Terraform state throughout the run.

```bash
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"

bash ansible/up.sh --mode prepare -e "@$COCO_STATE_DIR/rig.yml"
# Only after the node passes firmware/SNP preflight:
bash ansible/up.sh --mode fresh-install -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

These commands reuse existing infrastructure. `--plan-tf` plans only; `--apply-tf` explicitly adds provisioning. See [the Latitude procedure](../docs/latitude-validation.md#plan-and-provision-in-stages) for plan review, provisioning and teardown.

Fresh install replaces the node's installed OS. It is not an in-place customer upgrade. `skip_bios_pause=true` is only an unattended acknowledgement after the required evidence exists. Successful installation closes the boot endpoint automatically; after an interrupted run, close it explicitly when safe:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook   ansible/playbooks/site.yml --tags pxe-stop -e "@$COCO_STATE_DIR/rig.yml"
```

The optional public console edge defaults on. Set `public_console_enabled: false` in the external environment file when it is not needed.

## Discovery and current machine inputs

Discovery saves only validated node names, server IDs and MAC addresses in `$COCO_STATE_DIR/discovery/node-macs.json`. It does not write `group_vars/discovered.yml`. A new discovery attempt invalidates older bindings before querying the provider, and a failed attempt cannot supply stale bindings to a later render.

The renderer requires cached names/server IDs to match the current machines, preserves current disk, VLAN/IP and NIC-name inputs, and checks required internal/public MACs. A public MAC requires an `external_if` name so that the rendered configuration can hold that NIC down. Leave both fields empty only for verified hardware without a public NIC. Explicit verified MAC inputs remain supported. Re-run discovery after any reprovisioning; a plan name does not identify a physical machine. `-e machines=...` and the single-node `node_*` overrides are supported.

## Credentials and generated state

Keep pull secrets, private SSH keys, vault files, Terraform state, boot tokens, kubeconfigs and recovery material in private external storage. Git-ignored files inside the checkout are not an exception. `pull_secret_src` and `node_ssh_pubkey_src` stage the supplied controller files; Ansible reads the protected registry password on the bastion without printing it.

Generated install configuration and assets live in root-owned directories on the bastion. Provider request journals are kept outside replaceable installer assets, so an interrupted or ambiguous request cannot be forgotten by regenerating the PXE files.

The public PXE copies use `/var/www/coco-boot-artifacts`, separate from the private `/opt/install` tree. Preparation checks that the nginx worker can read the staged initrd before publishing it. Keep private installer directories at `0700` and source configuration files at `0600`; do not relax their permissions to make nginx work. `pxe-stop` removes the published copies and nginx boot configuration.

## Validation and topology limits

The `machines` list is the configuration seam for hosts, but multi-node and separate-Trustee topologies still require their own validation. Do not infer them from SNO. Firmware, endorsement material and launch references must match each eligible worker. Node egress enforcement is a separate check from bastion egress tuning and the provider's inbound firewall.

Run `make ansible-lint` for syntax/lint checks and `make lint` for the complete required offline checks. See [capability status](../docs/capability-status.md) for the hardware-backed acceptance proofs.
