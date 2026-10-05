# Modernization status

Started October 5, 2026. Branch: `codex/current-products-reliability`.
Baseline: `2fec0a4a132f1c201696537fd7737b0907a5cfd3`.

## Scope

Update product versions, repair setup and automation, simplify documentation and diagrams,
and validate the workflow on new Latitude.sh infrastructure. The owner confirmed **AMD
SEV-SNP only**. Intel and GPU work are outside this effort.

## Implemented for review

- One resolved release inventory: OCP 4.20.39, OSC 1.13.1 and Trustee 1.2.1,
  exact supporting operators, authenticated bundles/related images, coco-tools and UBI minimal.
  [Artifact evidence](docs/validation/release-resolution-2026-10-05.json) records immutable identities;
  an oc-mirror v2 dry run passed with 220 planned images.
- Checksum-verified tools; input-bound mirror/PXE reuse; prepare/fresh-install/verify modes;
  persistent provider request journals; automatic boot-endpoint closure after successful install.
- Latitude provider 4.6.0 with locked dependencies and implicit reinstallation disabled.
- Explicit cluster contexts, scoped AMD worker pools, checked Manual InstallPlans, completed
  CVO checks, and actual Kata/node/MCP reconciliation gates.
- TrusteeConfig ownership/migration checks, Restricted defaults, lossless reference conversion,
  current serving-config verification and omission-preserving lab resource updates.
- VCEK URL/report provenance, TCB-change invalidation, certificate checks and separate collection/seeding.
- Shared workload/initdata renderer; exact approved-byte reuse; separate initdata and launch-reference
  proofs; allow/deny/restore/recovery controls; attributable failures and protected recovery files.
- Signed-image preparation independent of encryption; transport errors cannot pass as signature denial.
- Raw-node private-link qualification checks the selected VLAN, route, ARP, registry TLS, DNS and NTP
  before reinstall; service probes bind to the reviewed private interface and source address.
- Current guides and flowcharts, historical-baseline labels, and retired duplicate bastion helpers.
- Required offline CI checks on Linux/macOS plus Terraform validation.

## Validation performed locally

The complete offline suite passed on October 5 after the live bootstrap fixes. It covers
Python regression tests, release/worker/VCEK/mirror tests and 10 OPA memory-policy cases,
plus ShellCheck, shell syntax, all four overlays,
Ansible syntax/lint and local documentation links. Both Terraform modules pass format and
schema validation with provider 4.6.0. No live provider, cluster or SSH operation was used
for these checks. GitHub CI results are recorded separately on the pull request.
The later conflicting-Terraform-state guard also passed its four focused wrapper tests.

## Required before deployment and completion

1. Complete the Latitude hardware run under the approved $150 total budget.
   The Miami replacement passed raw-host SNP acceptance. Authenticated artifact resolution, mirror transfer and a
   zero-change repeated preparation passed. Artifact preparation is distinct from hardware acceptance.
2. Resolve the failed private VLAN path, then verify networking and SNP under the installed RHCOS kernel.
   A public-routed lab can advance product testing separately; its current profile is render-only
   until ingress protection across boot and the installed node is validated.
   The locked-user bootstrap passed on a fresh Miami bastion; it does not establish node connectivity.
3. Run the documented installation and AMD proofs,
   then repeat a clean run while recording timings and manual interventions.
4. Complete guest signed-image enforcement. Host signature verification and the unsigned
   negative control passed through the actual registry. Test encrypted images only on
   an independently reviewed payload containing the host-pull fix and compatible operands.
5. Record hardware results, teardown and remaining product limitations. Document the inputs
   needed for a separate customer upgrade rehearsal; fresh-install evidence does not prove an in-place upgrade.

[OpenShift CRI-O PR 82](https://github.com/openshift/cri-o/pull/82) merged into `release-5.0`
on October 5. This is progress for encryption, not evidence that OCP 4.20.39 includes the fix.

## Resume

Use this branch and the [current quickstart](docs/current-quickstart.md),
[Trustee guide](docs/trustee-current.md), [capability definitions](docs/capability-status.md)
and [Latitude acceptance plan](docs/latitude-validation.md). The initial audit is retained
in [the adjustment plan](docs/design/current-version-adjustment-plan.md).

Credentials and dedicated SSH keys are held outside Homelab. The validation uses the Test project,
m4-metal-small ($0.81/hour) and m4-metal-medium ($1.25/hour), with a $150 total cap.
The bastion completed mirroring and repeated preparation with zero changes. Signed-image
preparation passed host verification, including an attributable unsigned-control rejection.
The preserved controls were [restored on the Miami mirror](docs/validation/latitude-mia2-signed-controls-2026-10-05.json)
with unchanged image/signature digests; both verification and an unchanged rerun passed.
The first Dallas node delivered EPYC 7313P / H12SSW-NTR / BIOS 2.3 and failed RMP/SNP checks
following saved firmware settings and a complete exposed-menu sweep. It was destroyed and
provider deletion verified. The [Miami replacement](docs/validation/latitude-mia2-host-2026-10-05.json)
delivered EPYC 9124 / H13SST-G / BIOS 1.6; five ordinary settings enabled full-memory RMP
coverage and SNP. It passed the raw-host gate in UEFI mode, with a recovered INIT retry retained
in the evidence. The old firmware remains a security gap. The latest cloud-init passed on a
fresh Miami bastion, including key-only SSH, a locked account and empty module error lists.
That comparison host was retired after preserving evidence. The Dallas bastion was also
destroyed after its unique signing artifacts were backed up and cryptographically verified.
No firmware flash or support outreach occurred. See [firmware preflight](docs/amd-firmware-preflight.md).

The current [private network check](docs/validation/latitude-mia2-network-2026-10-05.json)
fails across three hosts and two VLANs, including a same-rack comparison. Correctly tagged
ARP leaves the private interfaces, but corresponding peer frames are absent. The provider
root cause is unproven. The medium-class comparison disappeared from the provider inventory
before completing deployment; cause unknown. Its remaining resources were removed and absence
verified. No further comparison machine was allocated.
Installation waits for private mirror, DNS and NTP reachability.

Live validation found and repaired a readiness-marker permission issue. Actual oc-mirror
output also exposed resource-kind and filtered-catalog identity assumptions. The repaired
normalizer passed against the real registry, preserved release signatures, and matched all
five selected operator records. [Dated evidence](docs/validation/latitude-preflight-2026-10-05.json)
records these preparation results and the failed host gate.
Installer artifact generation, public PXE Range serving and unchanged-artifact reuse also passed
after separating the nginx webroot from private installer files. Endpoint cleanup was verified.
This run used SELinux Permissive; enforcing mode and actual node boot remain unverified.
The [later live cleanup test](docs/validation/latitude-pxe-cleanup-2026-10-05.json) passed both
entry points and a deliberate readiness failure: rescue closed publication while preserving
private sources and unchanged artifacts.
[CI passed on c8e7869](https://github.com/shpwrck/openshift-confidential-containers/actions/runs/37347071907)
for Ubuntu, macOS and Terraform, including the private-link checker. Later work still requires its own checks.
Keep Terraform state, cost records, boot assets, kubeconfigs and proof recovery material
outside the checkout and Homelab. Historical rig results do not validate this release set.

The [public-route feasibility check](docs/validation/latitude-mia2-public-route-2026-10-05.json)
passed node-to-registry trusted TLS and pinned-installer manifest generation. The
[Chrony repair](docs/validation/latitude-mia2-chrony-2026-10-05.json) passed a private-source local
NTP response and zero-change rerun. Public service and boot protection remain prerequisites.
