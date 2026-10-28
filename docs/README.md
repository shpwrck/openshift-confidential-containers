# Documentation

New here? Read the [project README](../README.md) first: it explains what this
repository does, lists the guides in the order you use them, and has a glossary.
Then start with the [quickstart](quickstart.md). The
[release manifest](../install/release-manifest.json) defines the selected versions;
[validation results](validation.md) describe what was actually tested.

Guides in the order you use them:

| Step | Guide |
|---|---|
| 1. Order the rig, set the BIOS, install OpenShift and the CoCo Operators | [Quickstart](quickstart.md) |
| 2. Choose other plans, or order by hand | [Cherry Servers setup](cherry-servers.md) |
| 3. Check an untested board's BIOS and firmware | [Firmware preflight](amd-firmware-preflight.md) |
| 4. Configure attestation and secret release | [Trustee setup](trustee.md) |
| 5. Let the confidential VM pull images | [Guest images](guest-images.md) |
| 6. Prove the security controls work | [Capability tests](capability-status.md) |

Reference:

| Task | Guide |
|---|---|
| Understand the components and sequence | [Architecture](architecture.md) |
| Diagnose a failed install or workload | [Troubleshooting](troubleshooting.md) |
| Refresh certificates and policies, or reset a test cluster | [Maintenance](maintenance.md) |
| Move to newer product versions | [Release resolution](release-resolution.md) |
| Plan a customer deployment or upgrade | [Customer planning](customer-planning.md) |
| See what was tested and when | [Validation results](validation.md) |
| Run the offline checks | [Contributing](contributing.md) |

Component references: [Ansible](../ansible/README.md), [installer artifacts](../install/README.md),
[GitOps](../gitops/README.md), [scripts](../scripts/README.md) and [tests](../tests/README.md).
