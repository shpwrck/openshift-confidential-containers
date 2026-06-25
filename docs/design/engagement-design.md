# Engagement Design — OpenShift Confidential Containers (air-gapped SEV-SNP)

Status: draft · Last updated 2026-06-25 · Owner: (internal) (Red Hat)

This is the synthesis of the setup grilling. It records **why** each decision was made so a
future session (or the product-team handoff) can reconstruct the reasoning.

## 1. Purpose

Stand up CoCo for a customer and **prove each capability on a disposable rig before touching
the customer's cluster**. The validated runbook is a first-class deliverable because the CoCo
team reports the official docs are incomplete/inaccurate. Post-engagement: hand notes +
[`../defects/`](../defects/) to the Red Hat product/docs team (deferred — customer delivery first).

The repo's value-add over the colleague onboarding guide: convert that **linear manual guide
into portable GitOps**, and **automate the two hardware-bound pipelines** (VCEK OfflineStore
collection, Veritas RVPS generation) — the operator ships nothing for these, and VCEK
automation is a **customer sign-off gate**.

## 2. Constraints

- **Air-gapped / disconnected** — customer is, so the rig must be too (else we'd never hit the
  VCEK-cache failure mode). Rig simulates it with a bastion/mirror host + the SNO node
  egress-firewalled to reach only it. NOT egress-open.
- **No local SNP hardware** → rent bare metal. **Latitude.sh hourly** (chosen over OVHcloud
  monthly to avoid upfront cost). Default node: EPYC **Genoa (9004)**.
- **Bare-metal host path**, not peer-pods: the worker RHCOS kernel must be the SNP hypervisor
  host (cloud CVM/peer-pods would attest the guest, not give us the bare-metal Kata path).
- **Red Hat employee** → free subs, real Red Hat operators (OSC + Trustee), no eval clock.
- Asset progression must be **incremental a → b → c**.

## 3. Topology

| | Test rig | Customer |
|--|----------|----------|
| Cluster | **SNO** (control+worker on one node) | full **multi-node** bare metal |
| Trustee | secondary cluster (once node 0 proven) | **separate Trustee cluster** (verifier off the confidential workers) |
| Network | simulated air-gap (bastion + egress firewall) | true air-gap |

GitOps is therefore **topology-portable**: `base/` + overlays `{sno,customer} × {workers,trustee}`.
Install order (operators): **NFD → cert-manager → OSC → Trustee**.

## 4. Security / attestation

- Trust model: the verifier (Trustee) lives **off** the confidential workers (separate cluster).
- **VCEK air-gap path = Trustee-side OfflineStore.** (Reversed from the initial host-side-preload
  pick — see Decisions §6 and [[../notes]].) Host-side extended-report preload is RFC-only /
  AMD out-of-tree kernel, unusable on stock RHCOS.
  - `vcek_sources = [{ type = "OfflineStore" }]` (omit KDS for fully offline).
  - `KbsConfig.spec.kbsLocalCertCacheSpec` mounts per-chip secrets at
    `/opt/confidential-containers/attestation-service/kds-store/vcek/<hwid-lowercase>/vcek.der`.
  - Collect with `snphost show vcek-url` per socket → download `.der` on a connected host → carry in.
- Reference values via **Veritas** (`coco-tools:1.12 veritas --tee snp`), per hardware config.
- initdata (gzip+base64 TOML pod annotation) is HW-measured (HOST_DATA, 32 bytes / sha256 for SNP).

## 5. Validation (definition of "proven" per rung)

A rung is done only when reproduced from written steps on a fresh node **and** its negative
test passes:

| Rung | Happy path | **Negative test (the proof)** |
|------|-----------|-------------------------------|
| a — secret release | `cdh/resource/.../attestation-status` → `{"status":"success"}` | restrictive policy + wrong/empty RVPS (or tampered initdata) → **error, secret withheld** |
| b — encrypted image | pod Running | wrong measurement → key withheld → **pod won't start** |
| c — signed image | signed image pulls | unsigned/tampered image → `image_security_policy` **rejects** |
| air-gap | attestation succeeds offline | remove one VCEK / wrong-case HWID → **attestation fails** (proves the cache is load-bearing, not silently hitting a reachable KDS) |

CI (no hardware): `kustomize build`, kubeconform, `conftest`/OPA on the Rego policies, yamllint.
Hardware e2e is manual/scheduled on the rented node.

## 6. Key decisions (with reversals)

1. Provider = Latitude.sh hourly (cost). Rung-0 = prove SNP host before any GitOps (verify-first).
2. SNO rig, multi-node customer → portable base+overlays.
3. Separate Trustee cluster (real trust boundary), mirrored on the rig.
4. **VCEK: REVERSED to Trustee-side OfflineStore** after two independent sources showed
   host-side preload isn't production-ready on stock kernels.

## 7. Risks / open dependencies

- 🔴 **Fully air-gapped TDX is not supported upstream yet** ("watch this space"). The customer's
  TDX phase is blocked while disconnected — flag now, not later. SNP air-gap works.
- **VCEK re-provisioning on firmware/TCB change** is manual + undocumented; build it as a
  **re-runnable job** (covers one-shot too) since it's a sign-off gate.
- Trustee bug **#591** hardcoded `"Milan"` — broke Genoa/Turin KDS path. Build VCEK automation
  **generation-agnostic**; check Trustee version.
- Rig vs customer **CPU generation** unknown → gen-agnostic automation + regenerate RVPS on
  customer metal, so it's not a blocker. See [customer-scoping.md](customer-scoping.md).

## 8. Next artifacts

- `gitops/` base + overlays fleshed out from the onboarding guide (Steps 3–6).
- `scripts/collect-vcek.sh`, `scripts/gen-rvps-veritas.sh` automated + gen-agnostic.
- `docs/defects/` populated as the runbook is replayed on real hardware.
