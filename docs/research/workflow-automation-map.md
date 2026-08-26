# Workflow automation map for the OSC 1.12 / Trustee 1.1 playbook

Research date: **2026-08-26**

## Scope and interpretation

This note maps every numbered step in the three workflows in the
[getting-started and operations playbook](../getting-started-and-operations.md) to repeatable
actions, available repository commands, and production automation gaps. The fixed boundary is
OpenShift sandboxed containers (OSC) 1.12,
Red Hat build of Trustee 1.1, disconnected AMD SEV-SNP bare metal, local `kata-cc`, and a separate
trusted OpenShift cluster for Trustee.

Three status values are used:

- **Implemented (rig):** the repository has an executable helper, but this is evidence from the
  disposable SNO rig, not a statement that the helper is a supported production installer.
- **Partial:** a repository helper or Red Hat procedure covers only part of the required artifact or
  activity; production composition, review, evidence retention, or cluster separation remains.
- **Gap/manual:** there is no repository implementation for the required outcome. A command that
  merely exports live state does not turn an approval, recovery design, or change decision into
  automation.

All repository invocations below are anchored on the repository:

```bash
REPO=/path/to/approved/openshift-confidential-containers-checkout
make -C "$REPO" <target>
```

Every `oc` or `make` invocation must use the intended cluster context. The repository scripts rely
on the ambient `oc` context and do not prevent applying Trustee objects to the workload cluster.
Use separate `KUBECONFIG` values and verify `oc whoami --show-server` before any write. Red Hat's
versioned documentation is authoritative for product installation and update behavior; repository
helpers are local implementation evidence only.

## Workflow 1 — establish a net-new service

| Step and owner | Repeatable action / command | Inputs | Output artifact | Verification | Status |
|---|---|---|---|---|---|
| **1. Define service — service and data owners** | No script. Complete and approve HA01: use case, protected-data flow, administrator threat, exclusions, SLO, RTO, and RPO. | Business use case, data classification, threat model, service objectives | Signed HA01 | Both accountable owners approve; unresolved exclusions are explicit | **Gap/manual** — no HA template, schema, signature, or approval automation |
| **2. Freeze supported BOM — platform architect** | Capture live state with `oc get clusterversion version -o yaml`, `oc get csv -A -o yaml`, `oc get nodes -o yaml`, and the exact release/Operator image digests; compare it with the live [OSC 1.12 release notes][rh-release] and [compatibility guidance][rh-discover]. | Workload and Trustee contexts; intended OCP/OSC/Trustee z-streams; hardware/firmware identity | Dated HA02 BOM and support evidence | Installed CSVs, RHCOS and payload are the approved combination; reviewers record the date because Red Hat pages can change | **Partial** — state is exportable, but no repository BOM collector or compatibility evaluator exists |
| **3. Design separation and ownership — security architect / all teams** | No script. Produce HA03 architecture and HA04 responsibility/escalation register. | Trusted/untrusted domains, flows, failure domains, administrator groups, named primary/backup owners | Approved HA03 and HA04 | Trustee is on the separate trusted cluster; flows, approval boundaries, failure ownership, and backups are named | **Gap/manual** |
| **4. Prove infrastructure readiness — platform, hardware, network, PKI, registry** | On the workload context run `make -C "$REPO" verify-snp-host NODE=<node>` once for every eligible host, `make -C "$REPO" validate-sno-baseline`, and, for the rig mirror, `make -C "$REPO" mirror-content MIRROR_REGISTRY=<host:port>`. Use the [installation execution plan](../runbooks/install-execution-plan.md) for the local order. | Node names; CPU/BIOS/firmware state; DNS/NTP/routes; registry and catalog credentials; certificates/CA; capacity model | HA05 evidence: per-host readiness result, mirror inventory, DNS/NTP/TLS/route/capacity results | All intended nodes pass; ineligible nodes remain excluded; catalogs and images resolve internally; guest-to-Trustee and guest-to-registry paths are proven | **Partial** — SNP/SNO/mirror checks exist; no aggregate DNS, NTP, TLS, capacity, or disconnected-inventory evidence pack exists |
| **5. Establish Trustee — attestation team** | On the Trustee context, collect the normal VCEK bundle **once per eligible host** with `make -C "$REPO" collect-vcek NODE=<node>`; when KDS is unreachable, carry the emitted URL bundle to a connected host, run `OUT=<bundle> scripts/collect-vcek.sh --download`, return it, and rerun collection. Generate reference values with `make -C "$REPO" gen-rvps TEE=snp OCP_VERSION=<z-stream> PULL_SECRET=<file> INITDATA=<file> RVPS_OUT=<file> NODE=<node>`. Render local state with `make -C "$REPO" deploy-trustee ...` or `RENDER_KBSCONFIG_ONLY=1 scripts/apply-trustee.sh`, but use Red Hat's [`TrusteeConfig` Restricted production procedure][rh-trustee-config] for the product deployment. | Trustee context; one host name at a time; VCEK bundle; exact OCP release; pull secret; exact initdata; TLS/admin keys; AS/KBS policies; resource metadata | MA01: Restricted `TrusteeConfig` or approved advanced equivalent, generated state, per-host VCEK cache inventory, RVPS YAML, AS/KBS policy, resources, HA06 and HA09 references | `oc get trusteeconfig,kbsconfig,pods -A`; Trustee rollout healthy; Red Hat known-good attestation succeeds and known-bad evidence/resource is denied; generated RVPS is non-empty and applied | **Partial** — local deployment uses direct `KbsConfig`, permissive base policies, and may colocate Trustee; it does not implement the required Restricted, separate-cluster, monitored, backed-up production service |
| **6. Establish confidential runtime — platform team** | On the workload context, the rig runs `make -C "$REPO" install-coco-operators CATALOGSOURCE=<name>`. Product operation must follow the [OSC 1.12 bare-metal configuration chapter][rh-cc-config] for NFD, feature gate, `KataConfig`, node changes, and reboots. | Workload context; mirrored catalog; node pool/selector; maintenance capacity | MA03 baseline: Subscriptions/CSVs, NFD objects, feature-gate ConfigMap, `KataConfig`, eligible node list, live `RuntimeClass/kata-cc` | CSVs `Succeeded`; NFD labels only intended nodes; `KataConfig` ready; MCP stable; `oc get runtimeclass kata-cc -o yaml` shows the operator-created runtime | **Implemented (rig), partial for production** — `apply-sno.sh` also installs Trustee and Gatekeeper into the current cluster, which conflicts with the playbook's two-cluster production boundary |
| **7. Deploy a reference workload — workload and security teams** | Build/sign with `make -C "$REPO" build-rung-signed`; full sign/encrypt path is `COSIGN_PASSWORD=<secret> make -C "$REPO" build-rung-images`. Capture exact initdata and build the Pod as described in [Exact initdata and Kata policy handling](#exact-initdata-and-kata-agent-policy-handling). Render without writes with `RENDER_ONLY=1 scripts/apply-rung-image.sh` or execute a rig rung with `make -C "$REPO" run-rung-signed`. | Digest-pinned source/image; registry; signing key/password; optional encryption key/KBS URI; KBS URL/CA; complete Pod; complete reviewed Kata Agent policy | MA02 image/signature/encryption/initdata/policy evidence and MA03 immutable Pod manifest | Signature helper passes; image reference contains `@sha256:`; decoded applied initdata is byte-identical; policy digest matches MA02; Pod uses `runtimeClassName: kata-cc`; non-production resource is received only after attestation | **Partial** — image mechanics exist, but no scan/SBOM/provenance pipeline and the current rung initdata omits `policy.rego` |
| **8. Prove allow and deny — security test owner / service owner** | Run `make -C "$REPO" test-rung WHICH=rung-kbs`, `... WHICH=rung-rvps`, and `... WHICH=rung-signed`, or `make -C "$REPO" repro-loop`. Preserve denied pods with `KEEP_DENIED_PODS=1`. | Workload and Trustee contexts/topology supported by the rig; digest refs; KBS URL; expected resource; test timeout | HA07 correlated allow/deny evidence; `loop-runs/repro-status.tsv` for the loop | A pass requires both an allowed release and a denial oracle; inspect Pod UID/node/events, guest/application output, Trustee decisions, registry result, and timestamps | **Partial** — A-C rig proofs and VCEK denial exist; encrypted-image proof is explicitly manual/upstream-blocked; the loop does not emit a complete evidence bundle and assumes one current context |
| **9. Make the service operable — SRE / service owner** | Use Red Hat [OSC observability][rh-observe] and [troubleshooting/must-gather][rh-troubleshoot] procedures plus local [debug surface](../runbooks/debug-surface.md) and [failure modes](../runbooks/failure-modes.md). No repository command installs dashboards/alerts, schedules synthetics, backs up Trustee, or performs restore drills. | Both cluster contexts; monitoring stack; alert routes; support image matching installed z-stream; backup destination and recovery credentials | HA08 operations package, HA09 backup/restore record, dashboards, alerts, synthetic results, support bundle | Force a safe denial and complete triage; restore Trustee into an isolated replacement; repeat one allow and one deny within RTO/RPO | **Gap/manual** for monitoring automation and DR; local diagnostics are operator-driven |

## Workflow 2 — onboard or change a workload

| Step and owner | Repeatable action / command | Inputs | Output artifact | Verification | Status |
|---|---|---|---|---|---|
| **1. Intake — workload owner** | No script. Open the release record naming data, namespace, immutable image subject, resource URI, runtime/storage/network needs, changed artifacts, expected release conditions, and date. | Current HA02/HA06/MA01-03 revisions and requested change | Reviewable intake record | Every changed machine artifact and approval owner is enumerated before build | **Gap/manual** |
| **2. Build MA02 — workload/supply-chain team** | `make -C "$REPO" build-rung-signed` or `COSIGN_PASSWORD=<secret> make -C "$REPO" build-rung-images`; then `make -C "$REPO" verify-rung-image-artifacts`. Create the exact initdata and complete policy using the procedure below. Run the organization's scanner, SBOM generator, and provenance builder against the same OCI digest. | Source/material digests; builder identity; registry; signing/encryption inputs; final Pod YAML; KBS/CA/image policy config | Digest-pinned OCI artifact, scan, SBOM, provenance, signature, optional encryption evidence, exact initdata, complete `policy.rego`, MA02 metadata | Local signature verification accepts the signed digest and rejects the unsigned control; key-wrap check returns a 32-byte key; SBOM/provenance subjects equal the released OCI digest; initdata/policy checks below pass | **Partial** — local build/sign/encrypt and negative signature controls exist; standardized scan, SBOM, provenance, and a production agent-policy generator do not |
| **3. Authorize the release contract — data owner / security** | No script. Bind the approved OCI identity, initdata/guest/reference state, resource URI, policy revisions, and expiry/review date in HA06. | MA02 digests; MA01 current/replacement revisions; data classification and expiry | Signed HA06 | Data and security approvers confirm least privilege and deny-by-default behavior | **Gap/manual** |
| **4. Configure versioned trust — attestation team** | Capture exact initdata with `EMIT_INITDATA=1 scripts/apply-rung-kbs.sh > initdata.toml`; render local AS/KBS policy with `scripts/render-measurement-policy.sh initdata.toml > measured-policy.yaml`; generate RVPS with `make -C "$REPO" gen-rvps ... RVPS_OUT=rvps.yaml`; use `oc diff -f <file>` and, after second-person review, `oc apply -f <file>` on the Trustee context. Manage signature keys, image policy and resources through the Restricted `TrusteeConfig` generated resources or an approved advanced `KbsConfig` path described by Red Hat. | Exact initdata bytes; supported release/hardware; existing and proposed AS/KBS/RVPS state; verification public key; resource metadata; approval | Versioned MA01 revision plus pre-change export/rollback reference | `oc get cm -n <trustee-ns> ... -o yaml`; non-empty intended values are live; Red Hat says applied generated-resource changes auto-sync but can take minutes; wait for behavior, then run allowed and denied retrieval | **Partial** — rendering/apply is repeatable, but local policy is a narrow measured-initdata demonstration, the base is permissive, and there is no safe revision/approval/rollback controller |
| **5. Deploy exact MA03 — platform team / workload owner** | Render locally with `RENDER_ONLY=1 scripts/apply-rung-kbs.sh` or `RUNG=signed RENDER_ONLY=1 scripts/apply-rung-image.sh`; review and apply the resulting digest-pinned manifest through the production GitOps path. The rig's `make -C "$REPO" run-rung-*` deletes/recreates a Pod directly and is not a production release controller. | Approved MA01/MA02/HA06 revisions; dedicated Namespace/ServiceAccount; digest-pinned Pod; initdata annotation; resources/placement/network/storage | Immutable MA03 deployment revision | Live Pod UID/node/runtime/imageID/initdata digest equal the approved revision; node is eligible; resource requests include PodVM overhead; no protected material is in YAML or initdata | **Partial** — renderer exists; local examples use `default`, implicit ServiceAccount, and incomplete placement/network/storage controls |
| **6. Prove release gates — security test owner / SRE** | `make -C "$REPO" test-rung WHICH=<rung>` for paired controls; `scripts/negative-test.sh rung-rvps` exercises untampered control then tampered initdata denial and restores the test policies; `scripts/negative-test.sh rung-signed` proves an unsigned control is denied; `scripts/negative-test.sh air-gap` swaps/restores covered VCEK material. Add explicit forbidden-resource, missing-key, TLS/collateral, and application tests where relevant. | Exact proposed MA01-03; non-production protected resource; expected denial oracles; evidence location | HA07 with correlated allow and applicable denial cases | Denied workload never obtains the resource or reaches the protected operation; positive control proves the environment was capable of success; base policies are confirmed restored after the rig test | **Partial** — tests cover selected local cases, not the complete playbook denial matrix; encrypted image remains manual |
| **7. Promote exact revisions — service owner / change authority** | No repository promotion command. Production GitOps must promote the exact already-tested OCI digest and MA01/MA02/MA03 revisions; rebuilding is prohibited. | Signed HA07; approved immutable revisions; rollback matched set | Production change record and Git revision | A content/digest comparison proves production inputs equal test inputs; change record identifies matched rollback set | **Gap/manual** |
| **8. Observe and close — SRE** | Follow [OSC observability][rh-observe]; capture `oc get pod -o yaml`, events, image IDs, node/runtime class, Trustee rollout/log decisions, registry result, capacity, latency, and application synthetic result. Use the local [debug surface](../runbooks/debug-surface.md) only as a diagnostic supplement. | Observation window, SLO, Pod UID, both cluster contexts, MA01-03 revision IDs | HA08/release observation evidence | Startup, attestation, resource release, registry, capacity/latency, and application behavior meet the release conditions for the full window | **Partial/manual** — product metrics and queries exist; no repository dashboard, alert, correlation, or closeout automation |

## Workflow 3 — upgrade or security-sensitive platform change

| Step and owner | Repeatable action / command | Inputs | Output artifact | Verification | Status |
|---|---|---|---|---|---|
| **1. Scope — change owner / platform** | Export current product and desired state as in Workflow 1 step 2; manually complete HA10 with before/after HA02, environment, reason, window, dependencies, stop and rollback triggers. | Current/live BOM, intended errata/z-stream, Red Hat support position | HA10 and before/after HA02 | Every affected environment and immutable version is named | **Gap/manual** — no HA10 generator or authoritative future-state resolver |
| **2. Assess impact — security / component owners** | No script. Review change impact on guest measurements, RVPS, AS/KBS policy, signatures/keys, TLS/admin trust, per-host VCEK/collateral, node reboots, capacity, registry/mirror, and applications. Use [OSC release notes][rh-release], [OSC update procedure][rh-osc-update], and [Trustee update procedure][rh-trustee-update]. | Vendor change notes/advisories, HA02, MA01-03, hardware and certificate inventory | Owned impact matrix | Each affected artifact has an owner, regeneration action, test, and rollback dependency | **Gap/manual** |
| **3. Protect — attestation / platform** | No repository backup/restore command. Exporting YAML is insufficient by itself: back up source-of-truth manifests, policies, RVPS/reference data, resources/backends, VCEK cache, credentials, certificates/keys, and cluster configuration through approved protected systems; restore them into an isolated replacement. | MA01/MA03 desired state, Secret/backend inventory, encryption key and recovery access, RPO/RTO | Encrypted backup-set ID and HA09 restore evidence | Replacement Trustee starts and passes an allowed and denied request; recovered revisions/digests equal backup inventory; measured RTO/RPO meets target | **Gap/manual** — neither Red Hat chapter reviewed nor the repository provides end-to-end Trustee DR automation |
| **4. Rehearse — change owner / affected teams** | In a non-production mirror run the documented product sequence, then `make -C "$REPO" validate-sno-baseline`, `make -C "$REPO" test-rung WHICH=<rung>`, or `make -C "$REPO" repro-loop`. Do not treat SNO `uninstall-coco`/reinstall as a production rollback rehearsal. | Mirrored exact update payload/catalog/images; production-like policy/network/capacity; representative MA01-03 | Timestamped lab implementation record | Same sequence and immutable inputs intended for production; operator/runtime, allow/deny, application, monitoring, backup and rollback gates recorded | **Partial** — rig can exercise selected rungs but not the complete production topology or lifecycle |
| **5. Re-establish trust — attestation / hardware / workload / platform** | Regenerate only affected artifacts: run the normal `collect-vcek NODE=<node>` once for each affected host when firmware/TCB requires refresh; regenerate RVPS with `gen-rvps`; rebuild AS/KBS policy from exact initdata; rebuild/sign images only if their contents changed; retain old matched revision. | Change impact matrix; post-change hosts/release; exact initdata; old and new keys/policies/references | Versioned replacement MA01/MA02 artifacts and retained rollback set | Post-change known-good succeeds; old/wrong state and forbidden resource deny; reviewers verify no broadening; applied revision is recorded | **Partial** — helpers generate pieces, not a transactionally versioned trust bundle |
| **6. Prove all gates — security / SRE** | Run `make -C "$REPO" lint`, `make -C "$REPO" validate-sno-baseline`, paired `test-rung` controls, application tests, product monitoring checks, isolated restore, and the approved rollback rehearsal. | Candidate versions and trust artifacts, predefined gate/oracle list | HA07, HA08, HA09, rollback result | All gates pass without weakening policy; rollback restores the complete matched set rather than only the Operator or Pod | **Partial** — platform/rung checks exist; backup, full monitoring and full rollback proof remain manual |
| **7. Authorize — change authority** | No script. Approve production sequence, communications, window, observation period, stop conditions, and named rollback authority. | Complete steps 1-6 evidence | Formal go/no-go decision | No missing owner, gate, recovery access, or pending support determination | **Gap/manual** |
| **8. Execute — platform / attestation teams** | Follow the live [OSC 1.12 update procedure][rh-osc-update]: update OCP first because RHCOS carries Kata/runtime dependencies, then update the OSC Operator. Follow the matching [Trustee 1.1 update procedure][rh-trustee-update]. Record every command and health result; regenerate/reference-test affected RVPS after OCP/OSC change as Red Hat directs. | Approved runbook; mirrored payload/catalog; both contexts; versioned trust replacements; maintenance capacity | Timestamped implementation log and live health evidence | OCP/MCP/nodes healthy before OSC; Operator CSVs and operands healthy; Trustee healthy; `kata-cc`, allow/deny and application gates pass at each approved checkpoint | **Partial/manual** — product ordering is defined, but this repository has no update orchestration. Its destructive SNO uninstall targets are not rollback |
| **9. Accept and retire — service owner / security / SRE** | No script. Update HA02, MA01, HA07, HA08, HA09 and HA10; retain or destroy old revisions according to the approved matched-set rollback and data-retention decision. | Production evidence and observation window; old/new inventories | Closed HA10 and explicit old-revision disposition | Observation window passes; one current allowed and denied result is accepted; no obsolete key/resource remains usable contrary to policy | **Gap/manual** |

## Exact initdata and Kata Agent policy handling

This is the minimum deterministic lifecycle implied by Workflow 1 step 7 and Workflow 2 steps 2,
4, and 5.

1. **Freeze the final Pod first.** Resolve every image to `@sha256:...`, include init containers,
   volumes, resources, environment, security context, network/storage dependencies, and the final
   KBS/registry configuration. Policy generation against an earlier manifest is not reproducible.
2. **Generate and review a complete Kata Agent policy.** Red Hat's [OSC 1.12 configuration
   chapter][rh-cc-config] requires a restrictive production policy and warns that a custom policy
   completely replaces the default: omitted request rules are denied. It specifically calls out
   disabling `ExecProcessRequest` for production. Upstream documents the version-dependent
   [`genpolicy` workflow and policy semantics][kata-policy]. This repository has no wrapper pinned to
   the OSC 1.12 guest assets, so the production build job must record the generator image/binary
   digest, command, input Pod digest, complete output `policy.rego`, manual edits, reviewer, and
   policy SHA-256. Do not append a small rule fragment to a hidden default.
3. **Create the exact initdata source.** Add the complete reviewed policy as `policy.rego` alongside
   the exact AA/CDH configuration described by the [upstream initdata specification][initdata-spec].
   The local deterministic rig source can be emitted with:

   ```bash
   REPO=/path/to/approved/openshift-confidential-containers-checkout
   KBS_URL=<trusted-route> MIRROR_CA=<ca-file> \
     EMIT_INITDATA=1 "$REPO/scripts/apply-rung-kbs.sh" > initdata.toml
   sha256sum initdata.toml policy.rego
   ```

   The emitted local source currently contains AA/CDH configuration but **not** `policy.rego`; it is
   therefore a measurement-test input, not a production MA02 implementation.
4. **Encode exactly once and bind the annotation.** The repository helper currently assumes
   gzip-then-base64:

   ```bash
   INITDATA_ANNOTATION=$("$REPO/scripts/encode-initdata.sh" encode initdata.toml)
   ```

   Apply it as `io.katacontainers.config.hypervisor.cc_init_data` to the final Pod. The helper itself
   warns that the transform must be verified against the exact OSC 1.12 guest build before first
   use; the Red Hat chapter is the product authority.
5. **Prove the applied bytes, not just the source file.** After applying the Pod:

   ```bash
   oc -n <namespace> get pod <pod> \
     -o jsonpath='{.metadata.annotations.io\.katacontainers\.config\.hypervisor\.cc_init_data}' \
     > applied-initdata.b64
   "$REPO/scripts/encode-initdata.sh" decode "$(<applied-initdata.b64)" > applied-initdata.toml
   cmp initdata.toml applied-initdata.toml
   sha256sum initdata.toml applied-initdata.toml
   ```

   Record the source digest, encoded-value digest, applied Pod UID, and expected/measured
   attestation claim. `cmp` proves repository encoding round-trip only; the untampered-control plus
   tampered-denial test proves that the live evidence/policy binding is load-bearing.
6. **Treat any modification as a full replacement.** A changed Pod, image, AA/CDH configuration,
   CA, KBS URL, registry mapping, or Kata policy produces a new initdata and policy revision. Re-run
   generation, hash, encode, RVPS/AS/KBS appraisal update, allow test, and relevant deny tests as one
   matched release.

## AS, KBS, RVPS, resource, and VCEK actions

| Artifact | Repeatable repository action | Apply / verify rule | Implementation boundary |
|---|---|---|---|
| AS and KBS measured-initdata policies | `scripts/render-measurement-policy.sh <exact-initdata.toml> > measured-policy.yaml` | Review `oc diff -f measured-policy.yaml`, apply on Trustee context, wait for generated-resource synchronization, run untampered allow and tampered deny | The renderer implements one narrow SHA-256 gate. It is not a complete production authorization policy, revision store, or approval workflow |
| RVPS reference values | `make -C "$REPO" gen-rvps TEE=snp OCP_VERSION=<z-stream> PULL_SECRET=<file> INITDATA=<file> RVPS_OUT=<file> NODE=<target-node>` | Inspect non-empty YAML, merge/apply by the [Red Hat RVPS procedure][rh-trustee-config], correlate exact release/hardware/initdata, and re-test | Output is generated but not automatically applied. Re-run after measured OCP/OSC/guest/workload inputs change |
| Trustee resources and image verification material | `make -C "$REPO" seed-trustee-secrets`; signed/encrypted-specific targets are `seed-rung-signed-secrets` and `seed-rung-image-secrets` | Verify only public verification material and approved protected resources are present; never commit signing private keys, raw encryption keys, pull secrets, or plaintext protected data | Local Kubernetes Secret-backed examples are not a KMS/HSM lifecycle or backup design |
| Per-host VCEK cache | `make -C "$REPO" collect-vcek NODE=<node>` once for each eligible host; use the script's URL/download carry flow when disconnected | Inventory covered host/HWID, certificate digest/issuer/validity, source, collection time/tool, Secret and mount; force a wrong-cache denial and restore | Single- and multi-socket hosts use exactly the same one-normal-run-per-host workflow. `--from-report` is an alternate diagnostic/import path, not an extra installation step |

## Image build, signature, and encryption actions

- `make -C "$REPO" build-rung-signed` builds/publishes the signed-only local artifact set and writes
  digest references and the public key under `rung-image-artifacts/`.
- `COSIGN_PASSWORD=<secret> make -C "$REPO" build-rung-images` builds the full signed/encrypted rig
  set. The raw encryption key and Cosign private key are sensitive local artifacts and must not be
  committed or copied into MA02.
- `make -C "$REPO" verify-rung-signed-signature` checks that the configured public key accepts the
  signed digest and rejects the unsigned control.
- `make -C "$REPO" verify-rung-encrypted-key-wrap` checks the KID/key wrap and confirms an unwrapped
  32-byte key; it does not prove a complete CRI-O/guest encrypted-image workload path.
- `make -C "$REPO" verify-rung-image-artifacts` runs the local artifact checks. It does not scan the
  image or create an [SPDX SBOM][spdx], [in-toto statement][in-toto], or [SLSA provenance][slsa].
  Those are explicit Workflow 2 step 2 gaps and must use the same [OCI manifest digest][oci-manifest]
  as the released Pod.

## Backup, rollback, monitoring, and support-capture finding

The repository does not currently implement any of these playbook outcomes end to end:

- encrypted, scheduled Trustee backup with backend/Secret/key/certificate inventory;
- isolated restore plus measured RTO/RPO and allow/deny proof;
- OSC or Trustee update orchestration;
- matched-set rollback of workload, initdata/policy, RVPS/AS/KBS state, keys/resources, and platform;
- dashboards, alert rules, scheduled synthetics, or cross-cluster correlation;
- a version-matched OSC must-gather wrapper or HA07/HA08 evidence archive.

The `uninstall-coco` and `validate-coco-uninstalled` Make targets are destructive disposable-rig
reset tools, not supported upgrade rollback. The Makefile variables `EVIDENCE_DIR` and `DIAG_DIR`
are not consumed by an evidence-collection target. Use the live Red Hat [observability][rh-observe],
[troubleshooting/must-gather][rh-troubleshoot], [OSC update][rh-osc-update], and
[Trustee update][rh-trustee-update] chapters and build customer-owned automation around their exact
supported commands and the approved backup systems.

## Material inconsistencies and gaps to correct before using the playbook as an executable runbook

1. [`scripts/apply-sno.sh`](../../scripts/apply-sno.sh) installs OSC, Trustee and other Operators in
   one current cluster. The playbook requires Trustee on a separate trusted cluster. Split the
   contexts and installation jobs before production use.
2. The local Trustee base uses direct [`KbsConfig`](../../gitops/base/trustee/kbsconfig.yaml),
   permissive AS/KBS policies, and empty default RVPS. It is not the Restricted `TrusteeConfig`
   baseline required by the playbook and described by Red Hat for production.
3. [`scripts/apply-rung-kbs.sh`](../../scripts/apply-rung-kbs.sh),
   [`scripts/apply-rung-image.sh`](../../scripts/apply-rung-image.sh), and
   [`initdata.example.toml`](../../gitops/base/workloads/initdata.example.toml) omit a complete Kata
   Agent `policy.rego`. The playbook's restrictive-policy requirement is therefore a real gap.
4. The initdata encoder assumes gzip+base64 and explicitly requires live version verification. Do
   not call its output OSC 1.12-compatible until round-trip, live measurement, allowed control, and
   tampered denial are all observed on the frozen build.
5. `render-measurement-policy.sh` hashes source bytes, but the source itself warns that the exact live
   measured encoding must be confirmed. Its output is not auto-applied and is not a broad
   production AS/KBS policy.
6. The Makefile phase description and disconnected bring-up runbook say to deploy Trustee before
   collecting VCEK, but `apply-trustee.sh` requires a populated bundle. The executable order is
   collect/download/import the per-host VCEK bundle first, then deploy Trustee.
7. `gen-rvps-veritas.sh` ends with stale “per distinct socket” wording. Do not carry that text into
   the operating procedure: the required AMD VCEK lifecycle is one normal collection per eligible
   host, with no special multi-socket branch.
8. `test-rung.sh` and `repro-loop.sh` comments still describe the RVPS rung as a skeleton/skip in
   places, while `negative-test.sh` now implements an untampered-control/tampered-denial measurement
   proof. This stale status text can make automation results ambiguous. The encrypted rung remains
   deliberately manual/upstream-blocked.
9. The local examples use the `default` namespace, implicit default ServiceAccount, and incomplete
   placement/network/storage definitions. They are not complete production MA03 sets.
10. Image scripts create useful digests/signature/key-wrap artifacts but no standardized scan, SBOM,
   provenance, approval envelope, or safe key lifecycle.
11. `make lint` is a useful shell-syntax, endpoint-parameterization, and Kustomize-render signal, but
    optional `kubeconform` and `conftest` failures are swallowed. It is not a strict schema or policy
    acceptance gate.
12. No repository action creates the required HA01-HA12 approvals, immutable evidence bundle,
   backup/restore proof, production promotion, update, or matched rollback. These steps must remain
   visibly manual/gap rather than being inferred from `oc apply` or a green Pod.

## Primary sources

### Red Hat product authority for this baseline

- [OSC 1.12 bare-metal guide][rh-guide]
- [OSC 1.12 discovery, support, and compatibility guidance][rh-discover]
- [OSC 1.12 configuration: NFD, feature gate, `KataConfig`, initdata, Kata Agent policy, and workload][rh-cc-config]
- [Red Hat build of Trustee 1.1 disconnected configuration: Restricted profile, generated resources, VCEK, RVPS, policy, resources, and verification][rh-trustee-config]
- [OSC 1.12 update procedure][rh-osc-update]
- [Trustee 1.1 update procedure][rh-trustee-update]
- [OSC 1.12 observability][rh-observe]
- [OSC 1.12 troubleshooting and support collection][rh-troubleshoot]
- [OSC 1.12 release notes][rh-release]

### Repository implementation evidence

- [Makefile](../../Makefile)
- [SNO/platform installer](../../scripts/apply-sno.sh) and
  [installation execution plan](../runbooks/install-execution-plan.md)
- [SNP host verification](../../scripts/verify-snp-host.sh) and
  [baseline validator](../../scripts/validate-sno-baseline.sh)
- [Trustee renderer/deployer](../../scripts/apply-trustee.sh),
  [VCEK collector](../../scripts/collect-vcek.sh),
  [RVPS generator](../../scripts/gen-rvps-veritas.sh), and
  [policy renderer](../../scripts/render-measurement-policy.sh)
- [Initdata encoder](../../scripts/encode-initdata.sh),
  [KBS rung renderer](../../scripts/apply-rung-kbs.sh), and
  [image rung renderer](../../scripts/apply-rung-image.sh)
- [Image build](../../scripts/build-rung-images.sh),
  [signature verification](../../scripts/verify-rung-signed-signature.sh), and
  [key-wrap verification](../../scripts/verify-rung-encrypted-key-wrap.sh)
- [Paired rung tests](../../scripts/test-rung.sh), [negative tests](../../scripts/negative-test.sh), and
  [reproducibility loop](../../scripts/repro-loop.sh)
- [Debug surface](../runbooks/debug-surface.md) and [failure modes](../runbooks/failure-modes.md)

### Upstream format specifications used only where Red Hat does not define the artifact schema

- [CoCo/Trustee initdata specification][initdata-spec]
- [Kata Agent policy and `genpolicy` semantics][kata-policy]
- [OCI Image Spec 1.1.1 manifest and digest model][oci-manifest]
- [containers/image signature policy schema][containers-policy]
- [SPDX 3.0.1][spdx], [in-toto Attestation Framework v1][in-toto], and
  [SLSA provenance v1.0][slsa]

Upstream formats explain the artifact contract; they do not expand Red Hat support. Rolling upstream
pages and tools must be pinned to and tested against the exact HA02 bill of materials.

[containers-policy]: https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
[in-toto]: https://github.com/in-toto/attestation/tree/main/spec/v1
[initdata-spec]: https://github.com/confidential-containers/trustee/blob/v0.19.0/kbs/docs/initdata.md
[kata-policy]: https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-the-kata-agent-policy.md
[oci-manifest]: https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md
[rh-cc-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc
[rh-discover]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/cc-discover_metal-cc
[rh-guide]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/index
[rh-observe]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/observe_metal-cc
[rh-osc-update]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/update-osc-cc-overview_metal-cc
[rh-release]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/release_notes/index
[rh-troubleshoot]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/troubleshoot_metal-cc
[rh-trustee-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/configure-trustee-overview_metal-trustee-disconnected
[rh-trustee-update]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/update-trustee-overview_metal-trustee
[slsa]: https://slsa.dev/spec/v1.0/provenance
[spdx]: https://spdx.github.io/spdx-spec/v3.0.1/
