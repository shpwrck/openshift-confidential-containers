# OpenShift Confidential Containers

Install and test AMD SEV-SNP confidential containers on a disposable bare-metal
OpenShift cluster. Customer deployment uses a separate Trustee trust domain.

The release set validated on **October 8, 2026** is **OCP 4.20.39, OpenShift
sandboxed containers (OSC) 1.13.1, and Red Hat build of Trustee 1.2.1**.
Exact operator, tool and image identities live in the
[release manifest](install/release-manifest.json).

The Cherry trial passed offline attestation, secret release, measured-initdata
and launch-reference enforcement, signed-image verification, and network isolation.
These checks passed again after removing and reinstalling the CoCo software.
**The rig has been deleted.** [Validation results and limits](docs/validation/README.md)
include the retirement receipt.

Encrypted images, customer upgrades and the separate customer Trustee deployment
remain unvalidated. The trial used public iPXE delivery before the private Agent OS
started; it does not prove private boot delivery from power-on.

## Start here

1. [Quickstart](docs/current-quickstart.md): prepare a controller and install on a supplied rig.
2. [Trustee setup](docs/trustee-current.md): offline collateral, references and resource policies.
3. [Capability tests](docs/capability-status.md): what each rung proves and how to run it.

Use the [documentation index](docs/README.md) for firmware, registry, troubleshooting
and maintenance guides.

```bash
make help           # available commands
make check-release  # local inventory consistency
make preflight      # require resolved artifact identities
make proof-plan     # list tests without cluster access
```

## Repository map

| Directory | Purpose |
|---|---|
| `install/` | Release inventory, ImageSet and installer templates |
| `ansible/` | Bastion preparation, explicit installation and verification |
| `gitops/` | Worker and Trustee manifests |
| `scripts/` | Setup, artifact preparation and proof runner |
| `tests/` | Hardware-free regression tests |
| `docs/` | Operating guides and dated validation receipts |

Keep credentials, keys, kubeconfigs, generated state and recovery files outside
this checkout and Homelab. The default state directory is
`$HOME/.local/state/openshift-confidential-containers`.
See [contributor setup](docs/contributing.md) for local checks.
