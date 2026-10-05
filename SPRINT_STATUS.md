# Modernization status

Started October 5, 2026. Branch: `codex/current-products-reliability`.
Baseline: `2fec0a4a132f1c201696537fd7737b0907a5cfd3`.

## Scope

Update product versions, repair setup and automation, simplify documentation and diagrams,
and validate the workflow on new Latitude.sh infrastructure. The owner confirmed **AMD
SEV-SNP only**. Intel and GPU work are outside this effort.

## Implemented for review

- One release inventory: OCP 4.20.39 payload, OSC 1.13.1 and Trustee 1.2.1 candidates,
  public coco-tools identity, UBI minimal 9.8 amd64, and explicit unresolved catalog entries.
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
- Current guides and flowcharts, historical-baseline labels, and retired duplicate bastion helpers.
- Required offline CI checks on Linux/macOS plus Terraform validation.

## Validation performed locally

The full offline suite passes: 74 Python regression tests, 45 release/worker/VCEK tests and
10 OPA memory-policy cases. Checks also cover ShellCheck, shell syntax, all four overlays,
Ansible syntax/lint and local documentation links. Both Terraform modules pass format and
schema validation with provider 4.6.0. No live provider, cluster or SSH operation was used
for these checks. GitHub CI results are recorded separately on the pull request.

## Required before deployment and completion

1. Resolve authenticated Red Hat catalog, bundle, related-image and diagnostics identities;
   select a verified mirror-registry archive/checksum. The deployment gate intentionally fails
   until this inventory is resolved. Artifact resolution is distinct from hardware acceptance.
2. Obtain Latitude project/access and Red Hat credential-file locations outside Homelab;
   review current AMD stock, site, networking, firmware access and infrastructure costs.
3. Provision new disposable infrastructure, run the documented installation and AMD proofs,
   then repeat a clean run while recording timings and manual interventions.
4. Prove signed-image transport through the actual registry. Test encrypted images only on
   an independently reviewed payload containing the host-pull fix and compatible operands.
5. Record hardware results and remaining product limitations. Rehearse the existing customer's
   upgrade with their actual cluster/Trustee state; the fresh-install path is not an in-place upgrade.

[OpenShift CRI-O PR 82](https://github.com/openshift/cri-o/pull/82) merged into `release-5.0`
on October 5. This is progress for encryption, not evidence that OCP 4.20.39 includes the fix.

## Resume

Use this branch and the [current quickstart](docs/current-quickstart.md),
[Trustee guide](docs/trustee-current.md), [capability definitions](docs/capability-status.md)
and [Latitude acceptance plan](docs/latitude-validation.md). The initial audit is retained
in [the adjustment plan](docs/design/current-version-adjustment-plan.md).

The owner will provide credentials; none were retrieved for this implementation. Keep secrets,
Terraform state, boot assets, kubeconfigs and proof recovery material outside the checkout and
Homelab. Historical rig results do not validate this release set. No new Latitude resources
have been created, and the overall hardware-validation objective remains unfinished.
