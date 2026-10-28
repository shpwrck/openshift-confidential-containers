# Scripts

Most scripts have a `make` target; run `make help` for the list, and prefer the
target because it passes the right defaults from the
[release manifest](../install/release-manifest.json). Scripts that change a
cluster need an explicit `WORKER_CONTEXT` or `TRUSTEE_CONTEXT` and never use your
current `oc` context by accident. Credentials and generated files go in
`COCO_STATE_DIR`, outside the checkout.

Where a script runs: **controller** is your Linux workstation or jump host,
**helper** is the mirror/DNS server, **node** is the AMD machine, and
**workstation** means Linux or macOS with `oc` access to the cluster.

## Controller and rig

| Script | Make target | Runs on | What it does |
|---|---|---|---|
| `env.sh` | (`source scripts/env.sh`) | controller | Sets up a terminal: on first use builds the Python environment and pinned CLIs and saves the Cherry Servers API key; then sets `COCO_STATE_DIR`, `PATH`, the key and `lab.env` |
| `order-rig.py` | `order-rig`, `cherry-plans`, `check-node-snp` | controller | Orders a tested Cherry Servers rig with Terraform, pins both host keys, starts the helper bootstrap, checks the node and writes the rig file; also lists the tested plans in stock and runs the node's SEV-SNP host check. Pure parts are in `lib/cherry_rig.py` |

## Tools and release inventory

| Script | Make target | Runs on | What it does |
|---|---|---|---|
| `install-dev-tools.py` | `install-dev-tools` | controller | Downloads checksum-verified OPA and Kustomize for the offline checks |
| `install-tools.sh` | `fetch-cli-tools` | controller, helper | Downloads checksum-verified `oc`, `openshift-install` and `oc-mirror` for the pinned OpenShift version. `source scripts/env.sh` runs it with `INSTALL_OC_MIRROR=0`, since only the helper runs oc-mirror |
| `verify-release.py` | `check-release`, `preflight` | anywhere | Checks that the manifest, ImageSet and Subscriptions agree; `--require-resolved` also requires every image to be pinned by digest. `--get <key>` prints one manifest value |
| `mirror.sh` | `mirror-content` | helper | Runs oc-mirror v2 for the selected ImageSet into the private registry |
| `normalize-mirror-resources.py` | (Ansible) | helper | Checks the mirrored catalog and writes the cluster's mirror resources |

## Hardware, network and install (called by Ansible)

| Script | Make target | Runs on | What it does |
|---|---|---|---|
| `render-helper-bootstrap.py` | (`order-rig`) | controller | Renders the mirror bootstrap template, with the manifest's pinned mirror-registry archive, as a root script to run on the helper over SSH, or as cloud-init user data; see [Cherry Servers setup](../docs/cherry-servers.md#ordering-by-hand) |
| `host-snp-check.sh` | `check-node-snp`, (Ansible) | node | Read-only SEV-SNP check on the provider's original OS; see [firmware preflight](../docs/amd-firmware-preflight.md) |
| `node-preflight.py` | (Ansible) | controller | The install's node checks before the erase: identity, UEFI boot, install disk and `host-snp-check.sh` over pinned SSH, with the output saved as evidence. Shares `lib/node_checks.py` with `check-node-snp` |
| `check-private-link.py` | (Ansible) | node | Read-only check that the node reaches the helper's registry (TLS), DNS and NTP over the private VLAN |
| `discover-node-macs.py` | (Ansible) | controller | Validates the node's NIC names and permanent MACs and merges them into the install inputs |
| `provider-identity.py` | (Ansible) | controller | Validates a Cherry Servers API response and prints only public identity fields |
| `serve-boot-artifacts.sh` | `serve-boot-artifacts`, `stop-boot-artifacts` | helper | Publishes or removes the iPXE boot files behind a random URL token |
| `boot-publication-paths.py` | (Ansible) | helper | Plans which published boot-file copies can be removed without touching the private originals |

## Cluster setup

| Script | Make target | Runs on | What it does |
|---|---|---|---|
| `connect-cluster.py` | `connect` | controller | Copies the cluster's kubeconfig from the helper, opens the API tunnel through it, writes `lab.env` and checks the cluster |
| `validate-sno-baseline.sh` | `validate-sno-baseline` | workstation | Read-only node, MachineConfigPool and catalog health check; `BASELINE_WAIT=<seconds>` waits while a new install settles |
| `repair-sno-baseline.sh` | `repair-sno-baseline` | workstation | Fixes one known MachineConfig drift (`kubelet.conf` content mismatch), with a backup |
| `apply-sno.sh` | `install-coco-operators`, `apply-overlay` | workstation | Installs NFD, cert-manager, OSC, Gatekeeper (and Trustee in a lab) in order, shows the matching InstallPlans in one table and approves them after one `yes`, and waits for the Kata runtime |
| `verify-snp-host.sh` | `verify-snp-host` | workstation | Checks SEV-SNP prerequisites on an installed OpenShift node through `oc debug` |
| `reset-lab.sh` | `reset-lab` | workstation | Resets the disposable lab to plain OpenShift: shows what goes, asks once, labels the lab namespaces, uninstalls and checks the cluster |
| `uninstall-coco.sh` | `uninstall-coco`, `validate-coco-uninstalled` | workstation | Removes the CoCo Operators and operands from a disposable lab, or checks that they are gone |

## Trustee

| Script | Make target | Runs on | What it does |
|---|---|---|---|
| `trustee-lab.py` | `trustee-lab` | controller | Runs the whole Trustee lab sequence: VCEK, bootstrap, mirror CA, initdata, guest command line, Veritas, one approval of the references, signed images built on the helper, configure; writes `trustee-lab.env` |
| `apply-trustee.sh` | `bootstrap-trustee`, `deploy-trustee` | workstation | `bootstrap` creates the TrusteeConfig and attaches VCEK collateral; `configure` publishes the reviewed resource policy, reference values and resources |
| `collect-vcek.sh` | `collect-vcek`, `seed-vcek` | workstation | Collects a node's VCEK certificate into external state, or publishes a collected bundle as Trustee Secrets |
| `gen-rvps-veritas.sh` | `gen-rvps` | workstation | Calculates the expected launch measurement from the release's guest artifacts with coco-tools |
| `review-references.py` | (none) | workstation | Adds the node's firmware levels from its VCEK request to the Veritas output and prints the reference set for review |
| `render-measurement-policy.sh` | `render-measurement-policy` | anywhere | Adds the initdata hash check to the vendor CPU attestation policy |
| `refresh-trustee.py` | (none) | workstation | Replaces Trustee's serving pods and confirms they serve the current configuration |
| `seed-trustee-secrets.sh` | `seed-trustee-secrets` | workstation | Creates synthetic resources for a disposable Permissive lab only |

## Test workloads and capability tests

| Script | Make target | Runs on | What it does |
|---|---|---|---|
| `build-rung-images.sh` | `build-rung-signed`, `build-rung-images` | workstation | Builds and pushes the signed, unsigned and (experimental) encrypted test images |
| `verify-rung-signed-signature.sh` | `verify-rung-signed-signature` | workstation | Checks the published signatures before any guest test |
| `verify-rung-encrypted-key-wrap.sh` | `verify-rung-encrypted-key-wrap` | workstation | Checks the encrypted image's layer key wrapping |
| `render-workload.py` | (none) | anywhere | Prints the exact initdata or test pod without contacting a cluster |
| `apply-rung-kbs.sh`, `apply-rung-signed.sh`, `apply-rung-encrypted.sh` | `run-rung-kbs`, `run-rung-signed`, `run-rung-encrypted` | workstation | Render and start one test workload (`RENDER_ONLY=1` prints it instead); share `apply-rung-image.sh` and `lib/apply-workload.sh` |
| `run-proofs.py` | `proof-plan`, `test-rung` | workstation | Runs the allow, deny, restore and recovery sequence for each [capability test](../docs/capability-status.md), then the network isolation checks |

## Repository checks

| Script | Make target | What it does |
|---|---|---|
| `lint.sh` | `lint`, `test` | Every offline check below plus the unit tests in [`tests/`](../tests/README.md), Kustomize renders and Ansible lint |
| `run-tests.py` | (in `lint`) | Runs the unit test modules side by side, as many at once as there are CPUs, and prints the full output of any that failed |
| `check-doc-links.py` | (in `lint`) | Local file and heading links in all Markdown |
| `check-mermaid.py` | (CI only) | Renders every Mermaid diagram; needs Node.js 22+ |
| `check-coco-workload-labels.sh` | (in `lint`) | Confidential workloads carry the label the Gatekeeper memory guard uses |
| `check-endpoint-parameterization.sh` | (in `lint`) | No script hard-codes the registry endpoint instead of `ARTIFACTORY_REGISTRY`/`MIRROR_REGISTRY` |

## Shared libraries (`lib/`)

| File | Used for |
|---|---|
| `release.sh`, `tee-profile.sh` | Loading defaults from the release manifest and the SNP profile |
| `cluster-context.sh` | Requiring explicit worker and Trustee contexts |
| `compat.sh` | Hashing and base64 that work with macOS Bash 3.2 and Linux |
| `apply-workload.sh`, `workload.py` | Rendering initdata and test pods |
| `lab_access.py` | The lab's state directory, rig file and pinned SSH access to the helper, for `connect-cluster.py` and `trustee-lab.py` |
| `trustee_config.py` | Offline checks and patches for Trustee resources |
| `vcek_bundle.py` | The external VCEK store with source and content hashes |
| `worker_install.py` | Rendering Operator stages and checking InstallPlans |
| `proof_core.py` | The capability-test runner's cluster access, locking and restore logic |
| `provider.py` | Normalizing Cherry Servers identity fields without credentials |
| `cherry_rig.py` | Choosing tested Cherry Servers plans and writing the rig file from what the servers report |
| `node_checks.py` | The read-only node checks before the erase, and their evidence file |
