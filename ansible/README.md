# Ansible workflow

Start with the [quickstart](../docs/current-quickstart.md) and
[provider setup](../docs/cherry-validation.md). Ansible prepares a supplied helper
and explicitly installs a disposable AMD node. Cherry allocation and BIOS setup
are manual; optional Terraform provisioning targets Latitude only.

## Modes

| Command | Behavior |
|---|---|
| `bash ansible/up.sh --mode prepare` | Default: prepare tools, mirror, DNS and NTP |
| `--mode fresh-install` | Prepare, qualify raw hardware/private link, then replace the node OS |
| `--mode resume-install` | Finish an accepted request with unchanged assets/inputs; no new rebuild |
| `--mode verify` | Check installed OCP payload and health without reinstalling |
| `--plan-tf` | Latitude Terraform plan only; no Ansible work |
| `--apply-tf` | Explicit Latitude provisioning before the selected mode |

Pass private environment inputs with `-e "@$COCO_STATE_DIR/rig.yml"`.
Fresh install is not a customer upgrade. Successful installation closes boot publication.
See [troubleshooting](../docs/troubleshooting.md) for ambiguous requests and cleanup.

## Phases and state

| Tag | Responsibility |
|---|---|
| `bastion-prep` | Checked tools, mirror transfer, DNS/NTP and helper preparation |
| `bios`, `discover` | Explicit BIOS acknowledgement and actual provider/NIC identity |
| `render`, `pxe` | Private installer config and input-bound boot artifacts/publication |
| `drive` | Journaled rebuild, platform wait, exact release/health and mirror-resource checks |
| `pxe-stop` | Remove published files/nginx config after they are no longer needed |

Discovery writes validated bindings to external `discovery/node-macs.json` and
invalidates stale data on failure. Rendering checks current names/server IDs and
preserves reviewed disk, network and NIC inputs. Recheck after reprovisioning.

Keep credentials, state, boot tokens, kubeconfigs and recovery files outside the
checkout and Homelab. Installer sources/assets remain private under `/opt/install`;
nginx receives separate copies under `/var/www/coco-boot-artifacts`. Provider request
journals live outside replaceable assets. Do not loosen private permissions for publication.

`public_console_enabled` defaults on; set it false when not needed. The `machines`
list supports rendering multiple hosts, but multi-node/customer topologies remain
unvalidated by the SNO trial. [Dated results](../docs/validation/README.md) define scope.
