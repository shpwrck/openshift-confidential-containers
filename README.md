# OpenShift Confidential Containers

Install and prove CPU confidential containers on a disposable bare-metal rig, then use the evidence to prepare a customer deployment. The active target is **AMD SEV-SNP**, with a separate Trustee trust domain for customer use.

**Current work targets OCP 4.20.39, OpenShift sandboxed containers 1.13.1, and Red Hat build of Trustee 1.2.1.** Authenticated catalog, bundle and image identities are resolved. The [Latitude rig was retired](docs/latitude-validation.md) after raw-host SNP passed with an old-firmware security gap and private networking blocked installation. [Replacement-provider research](docs/research/disconnected-amd-provider-selection-2026-10-08.md) rejects the checked AWS AMD metal types for legacy-only boot; OCI is excluded by the user. An [October 8 Cherry hourly trial](docs/validation/cherry-qualification-2026-10-08.json) has allocated a Genoa candidate in Chicago with a four-hour cleanup deadline. The raw SNP host and prepared private-service checks passed; mirroring completed and fresh installation is underway. RHCOS and guest proofs remain pending. Historical results from OCP 4.20.18 / OSC 1.12 / Trustee 1.1 do not validate the new set.

## Start here

1. [Current quickstart](docs/current-quickstart.md): prerequisites, external state, prepare/install/verify commands.
2. [Cherry validation](docs/cherry-validation.md): active trial, private networking and installation checks; [Latitude history](docs/latitude-validation.md) records the retired rig.
3. [Trustee 1.2 workflow](docs/trustee-current.md): Restricted configuration, migration, TLS, collateral and RVPS.
4. [Capability rungs](docs/capability-status.md): what each test proves, what remains blocked, and useful demos.
5. [Architecture and flowcharts](docs/architecture.md): component boundaries and the installation/proof sequence.

```bash
make help           # current entry points
make check-release  # local manifest consistency
make proof-plan     # list tests; no cluster access
make preflight      # fails until required artifact identities are resolved
```

[The release manifest](install/release-manifest.json) is the source of product versions, immutable payloads, TEE profiles and artifact verification. Deployment commands check it before making changes. Operator InstallPlans use Manual approval and are checked against that inventory.

## Capability ladder

| Test | Required evidence | Current status |
|---|---|---|
| A: `rung-kbs` | Confidential workload receives a synthetic resource; plain workload cannot use the guest data hub | New runner authored; hardware rerun pending |
| `rung-initdata` | Approved measured configuration runs; changed bytes are rejected while CPU checks remain active | Separate from RVPS; hardware rerun pending |
| B: `rung-rvps` | Actual guest launch reference allows release; removing that reference denies it | Trustee 1.2 format implemented; hardware proof pending |
| C: `rung-signed` | Signed digest runs; an unsigned/wrong-key digest is rejected by the guest | Registry signature transport must be proved |
| `air-gap` | Wrong selected-node endorsement denies attestation; restored collateral succeeds | SNP fixture implemented; network isolation evidence is separate |
| D: `rung-encrypted` | Encrypted guest image runs; changed measured configuration withholds its key | Experimental; released payload inclusion remains unverified |

Every proof starts fresh and requires a positive control, an attributable denial, verified restoration and successful recovery. Unrelated startup failures and skipped tests are not passes. Full acceptance also requires a clean repeat run and recorded network isolation. [Details and product evidence](docs/capability-status.md).

## Repository map

| Path | Purpose |
|---|---|
| `install/` | Release inventory, ImageSets and installer templates |
| `infra/latitude/` | Disposable bastion/node infrastructure |
| `ansible/` | Preparation, explicit fresh installation and read-only verification |
| `gitops/` | AMD worker and Trustee manifests |
| `scripts/` | Staged operations, artifact preparation and proof runner |
| `tests/` | Hardware-free failure/recovery fixtures |
| `docs/` | Current guides plus labeled historical investigation material |

Keep credentials, keys, Terraform state, installer assets and proof recovery files outside the checkout. The default working directory is `$HOME/.local/state/openshift-confidential-containers`. All live operations require an explicit cluster context. Destructive proof tests require explicitly marked disposable namespaces.

For local validation, use Python 3.12+, install [the development requirements](requirements-dev.txt) in an external virtual environment, then run `make install-dev-tools` and `make lint`. Add the printed tools directory to `PATH`. Linux is the provisioning controller; portable workstation scripts are also checked on macOS. These checks do not validate firmware, attestation or a disconnected installation.

Earlier procedures are retained for investigation and migration context; see [the documentation index](docs/README.md). Use the current guides for this release set.
