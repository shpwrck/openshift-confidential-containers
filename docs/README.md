# Documentation

Start with the [quickstart](current-quickstart.md). The
[release manifest](../install/release-manifest.json) defines the selected versions;
[validation results](validation/README.md) describe what was actually tested.

| Task | Guide |
|---|---|
| Understand the components and sequence | [Architecture](architecture.md) |
| Qualify AMD hardware and BIOS | [Firmware preflight](amd-firmware-preflight.md) |
| Prepare a supplied Cherry rig | [Cherry setup](cherry-validation.md) |
| Configure offline attestation and release policy | [Trustee setup](trustee-current.md) |
| Configure guest registry access | [Guest images](guest-images.md) |
| Run the capability rungs | [Capability tests](capability-status.md) |
| Diagnose a failed install or workload | [Troubleshooting](troubleshooting.md) |
| Refresh artifacts or reset a disposable lab | [Maintenance](maintenance.md) |
| Select and resolve a new release set | [Release resolution](release-resolution.md) |
| Prepare a customer deployment or upgrade | [Customer planning](design/customer-scoping.md) |
| Run local checks | [Contributing](contributing.md) |
| Find trial backups and retirement details | [Cherry leave-behind](runbooks/cherry-qualification/README.md) |

Component references: [Ansible](../ansible/README.md), [installer artifacts](../install/README.md),
and [GitOps](../gitops/README.md).
