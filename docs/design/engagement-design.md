# Design — OpenShift Confidential Containers (air-gapped SEV-SNP)

Status: draft · Last updated 2026-06-25

This is the synthesis of the setup grilling. It records **why** each decision was made so a
future session can reconstruct the reasoning.

## 1. Purpose

Stand up CoCo and **prove each capability on a disposable rig before touching the production
cluster**. The validated runbook is a first-class deliverable because the official CoCo docs
are reported incomplete/inaccurate; known doc/product gaps found during bring-up are tracked
separately and surfaced as upstream feedback.

The repo's value-add over a linear manual onboarding guide: convert that **linear manual guide
into portable GitOps**, and **automate the two hardware-bound pipelines** (VCEK OfflineStore
collection, Veritas RVPS generation) — the operator ships nothing for these, and VCEK
automation is a **production sign-off gate**.

## 2. Constraints

- **Air-gapped / disconnected** — the production target is, so the rig must be too (else we'd
  never hit the VCEK-cache failure mode). Rig simulates it with a bastion/mirror host + the SNO
  node egress-firewalled to reach only it. NOT egress-open.
- **No local SNP hardware** → rent bare metal. **Latitude.sh hourly** (chosen over a
  monthly-commit provider to avoid upfront cost). Default node: EPYC **Genoa (9004)**.
- **Bare-metal host path**, not peer-pods: the worker RHCOS kernel must be the SNP hypervisor
  host (cloud CVM/peer-pods would attest the guest, not give us the bare-metal Kata path).
- Asset progression must be **incremental A → B → C → D** (rung-kbs → rung-rvps → rung-signed → rung-encrypted).

## 3. Topology

| | Test rig | Production |
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
  - Collect the master socket with `snphost show vcek-url` → download `.der` on a connected host →
    carry in. On 2P, each **other** socket's VCEK must come from an SNP report's CHIP_ID on that
    socket (host-side tools see only the master PSP) — see `docs/runbooks/multi-socket-vcek.md`.
- Reference values via **Veritas** (`coco-tools:1.12 veritas --tee snp`), per hardware config.
- initdata (gzip+base64 TOML pod annotation) is HW-measured (HOST_DATA, 32 bytes / sha256 for SNP).

## 5. Validation (definition of "proven" per rung)

A rung is done only when reproduced from written steps on a fresh node **and** its negative
test passes:

| Rung | Happy path | **Negative test (the proof)** |
|------|-----------|-------------------------------|
| A — rung-kbs (secret release) | `cdh/resource/.../attestation-status` → `{"status":"success"}` | `make negative-test WHICH=rung-kbs`: with a valid attestation the secret is released (control), but with **no valid attestation the secret is withheld (403)**. Proves KBS gates release on attestation. |
| B — rung-rvps (measurement verification) | populated `snp_launch_measurement` present → secret released | `make negative-test WHICH=rung-rvps` auto-applies+reverts a restrictive measured-initdata policy: untampered pod releases (control), **valid attestation but wrong/absent measurement (tampered initdata) → secret withheld**. Proven on the rig 2026-07-01 (`init_data == sha256(initdata bytes)` confirmed as the measured HOST_DATA). |
| C — rung-signed (signed image) | signed image runs | `make negative-test WHICH=rung-signed`: unsigned/tampered image → `image_security_policy` **rejects** |
| D — rung-encrypted (encrypted image) *(MANUAL; upstream-blocked: cri-o/cri-o#10084 — excluded from the hands-off loop, a skipped D is not a failure)* | pod Running | wrong measurement → key withheld → **pod won't start** |
| air-gap | attestation succeeds offline | temporarily **swap each Trustee `vcek-*` Secret for a valid-but-wrong cert** (deleting the required-volume secret would only crash-loop KBS, not deny attestation), rerun an otherwise happy rung-kbs request → **attestation fails** (401, KDS-chain verify), then restore. Proves the cache is load-bearing, not silently hitting a reachable KDS. **Requires node egress locked**, else the wrong cert is silently repaired from the public KDS and the test falsely passes. |

> **Per-rung negatives (#17/#18, wired):** each rung's denial is its own — **A/rung-kbs** = bare attestation (a non-CoCo / non-kata pod cannot attest → secret withheld); **B/rung-rvps** = measurement (valid attestation, wrong/absent measured-initdata → withheld; appraised measurement is `HOST_DATA == sha256(initdata)`, with per-rig `snp_launch_measurement` RVPS reference values from `make gen-rvps` and `gitops/base` kept permissive `[]`); **C/rung-signed** = signature; **air-gap** = VCEK/OfflineStore. `make negative-test WHICH=all` runs kbs + rvps + signed + air-gap (rung-encrypted / D is manual).

CI (no hardware): `kustomize build`, kubeconform, `conftest`/OPA on the Rego policies, yamllint.
Hardware e2e is manual/scheduled on the rented node.

## 6. Key decisions (with reversals)

1. Provider = Latitude.sh hourly (cost). Rung-0 = prove SNP host before any GitOps (verify-first).
2. SNO rig, multi-node customer → portable base+overlays.
3. Separate Trustee cluster (real trust boundary), mirrored on the rig.
4. **VCEK: REVERSED to Trustee-side OfflineStore** after two independent sources showed
   host-side preload isn't production-ready on stock kernels.

## 7. Risks / open dependencies

- 🔴 **Fully air-gapped TDX is not supported upstream yet** ("watch this space"). The TDX
  phase is blocked while disconnected — flag now, not later. SNP air-gap works.
- **VCEK re-provisioning on firmware/TCB change** is manual + undocumented; build it as a
  **re-runnable job** (covers one-shot too) since it's a sign-off gate.
- Trustee bug **#591** hardcoded `"Milan"` — broke Genoa/Turin KDS path. Build VCEK automation
  **generation-agnostic**; check Trustee version.
- Rig vs production **CPU generation** unknown → gen-agnostic automation + regenerate RVPS on
  the production metal, so it's not a blocker. See [customer-scoping.md](customer-scoping.md).

## 8. Next artifacts

- `gitops/` base + overlays fleshed out from the onboarding guide (Steps 3–6).
- `scripts/collect-vcek.sh`, `scripts/gen-rvps-veritas.sh` automated + gen-agnostic.
- Known upstream doc/product issues tracked separately as the runbook is replayed on real hardware.
