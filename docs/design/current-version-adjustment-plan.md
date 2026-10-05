# Current-version adjustment plan

> Scope correction, October 5, 2026: the owner confirmed **AMD SEV-SNP only**. Intel suggestions below are historical planning context and are excluded from the active implementation and Latitude acceptance plan. See [the current quickstart](../current-quickstart.md).

**Status:** proposal only; implementation and hardware validation have not begun.

**Reviewed:** October 2, 2026 (America/New_York).

**Repository:** `shpwrck/openshift-confidential-containers`, main at `2fec0a4a132f1c201696537fd7737b0907a5cfd3` (August 26, 2026).

**Customer baseline:** OSC 1.12 + Red Hat build of Trustee 1.1; tested rig OCP 4.20.18. The repository's active Operator defaults are OSC 1.12.1 and Trustee 1.1.0. These are historical test identities, not a current support recommendation.

## Recommendation

Update the repository as a reproducible evaluation tool for OSC 1.13 / Trustee 1.2. Start by fixing the places where changed inputs can silently reuse old state, then migrate Trustee deliberately, and add an explicit disconnected Intel TDX profile. Retain AMD SNP as the comparison path.

This is worthwhile because the review found identifiable causes of the brittle experience. A version-string update alone would carry them forward. The most consequential findings are:

1. Existing tools, mirrored content and PXE artifacts can survive a version change without being refreshed.
2. The low-level Trustee 1.1 configuration requires payload and ownership migration; the 1.2 Operator can remove ConfigMaps that this repository expects to manage itself.
3. Several scripts assume AMD SNP, even when the surrounding interface appears generic.
4. A green test result can overstate coverage: the current “RVPS” test proves measured-initdata gating, and stale passes can be reused after configuration changes.
5. The customer overlays remain incomplete. The proven disposable SNO path does not establish a separate-Trustee, multi-worker customer deployment.

The intended benefit is fewer hidden prerequisites, reliable reruns, and clear evidence about what works. Repository improvements must be described separately from Red Hat product improvements in the customer presentation.

## Scope and working assumptions

- CPU-only confidential containers; AMD SNP and disconnected Intel TDX. No GPU work.
- Preserve the baseline through the exact reviewed Git commit and its versioned documentation. Do not build two permanently maintained implementations unless a reproducible comparison requires it.
- Prefer a supported OCP 4.20 z-stream for the first comparison, if the current update graph and lifecycle permit it. This reduces variables while changing OSC and Trustee. A current OCP 4.22 evaluation is a separate option, not a prerequisite inferred from newer product versions.
- Treat fresh installation and in-place upgrade as distinct workflows. The existing provider installation path can reinstall a machine.
- Use explicit worker and Trustee cluster contexts for a customer topology. Keep co-located, permissive SNO behavior available only as an explicitly identified disposable test profile.
- No cluster, provider, Terraform, SSH, registry-push, or deployment actions were performed for this review. No credentials were collected. The only proposed repository addition in this review is this plan.
- In this workspace, future secret-bearing inputs and outputs must live outside `/mnt/c/Homelab`, as required by its AGENTS.md. Git-ignored files inside the checkout are not an exception. Review artifacts should contain resource names, digests and outcomes, not credentials or released secret values.

## Target versions: resolve before changing active defaults

The OSC 1.13 guide currently describes 1.13.1 and lists CPU-only bare-metal AMD SNP / Intel TDX as GA on OCP **4.19.38+, 4.20.29+, 4.21.24+, and 4.22.5+**. These are minimums, not the latest available patches. OCP 4.20.18 is below the listed 4.20 floor. The runtime is delivered through OCP/RHCOS, so an Operator update alone is insufficient. Recheck the live table before implementation and customer use. [Red Hat compatibility matrix][matrix]

| Component | Repository baseline | Planning target | Evidence still required |
| --- | --- | --- | --- |
| OCP | 4.20.18 | Supported 4.20 patch at or above 4.20.29 for the first comparison; optionally a separate 4.22 run at or above 4.22.5 | Actual supported update path, exact payload digest, platform lifecycle and matching installer |
| OSC | 1.12.1 | 1.13 family; 1.13.1 is the candidate reviewed | Selected mirrored catalog bundle, channel, CSV, Operator and operand digests |
| Trustee | 1.1.0 | 1.2 family; downstream 1.2.1 source reviewed | Catalog-to-source match, upgrade chain, CRD schemas, KBS and Operator digests |
| Supporting Operators | Existing NFD, cert-manager, Gatekeeper | Versions compatible with the selected platform | Exact bundle and related-image inventory; Intel DCAP dependencies for TDX |
| Tools and diagnostics | Older coco-tools / OSC diagnostics plus repeated CLI defaults | Versions matched to the chosen platform and products | Checksums/digests, target Veritas format, Trustee 1.2 must-gather image |

Record these in a small, non-secret bill of materials (BOM). It should cover release identities and image/tool references; keep networking, provider and site configuration in their existing files. Generate or validate the existing manifests against it rather than creating a new general-purpose configuration framework.

`startingCSV` is an installation starting point, not an upgrade lock. Today the bounded mirrored catalog helps hold the baseline while Subscriptions use automatic InstallPlan approval. Review that approval behavior before exposing a newer catalog to an existing cluster.

## Findings tied to current code

Line references below apply to the reviewed commit.

| Finding | Evidence | Adjustment |
| --- | --- | --- |
| Version defaults are repeated | `install/imageset-config.yaml:17`, `Makefile:11`, `ansible/group_vars/all.yml:16`, `scripts/install-tools.sh:14`, `scripts/gen-rvps-veritas.sh:42`, `gitops/base/operators/subscriptions.yaml` | One release BOM and a consistency check, including helper images and catalog names |
| Old binaries are accepted by existence | `ansible/roles/mirror_tools/tasks/main.yml:14`, `scripts/bastion-mirror-setup.sh:18` | Check requested version/checksum before reuse |
| Missing oc-mirror version falls back to latest | `scripts/install-tools.sh:41` | Fail with the missing artifact and required action; do not silently change the BOM |
| Changed ImageSet does not invalidate completion | `ansible/roles/mirror_push/tasks/main.yml:10` and `:26` | Bind completion to ImageSet/BOM digest and destination; record actual completion evidence |
| Old boot artifacts survive new inputs | `ansible/roles/pxe_serve/tasks/main.yml:52`, `ansible/roles/render_configs/tasks/main.yml:185` | Run-scoped assets or verified input fingerprints; regenerate when payload/config changes |
| Custom mirror workspace is ignored in one path | `scripts/mirror.sh:28` and `:52` | Derive cluster-resource output from the selected workspace |
| Fresh installation is not an upgrade | `ansible/roles/install_drive/defaults/main.yml:4`, `ansible/roles/install_drive/tasks/main.yml:11` | Separate entry points and identities; never route customer upgrade through provider reinstall |
| “Ready” does not verify requested versions | `scripts/apply-sno.sh:61`, `scripts/validate-sno-baseline.sh:26`, `ansible/roles/install_drive/tasks/main.yml:79` | Verify actual OCP payload, CSVs and operands against the BOM |
| Trustee deploy can reapply permissive/empty defaults | `scripts/apply-trustee.sh:221`, `gitops/base/trustee/kbs-configmaps.yaml` | Distinguish initial creation from update; preserve approved policy/reference/resource state |
| Runtime readiness assumes SNP | `scripts/apply-sno.sh:28`, `scripts/apply-rung-kbs.sh:71`, `scripts/apply-rung-image.sh:96` | Resolve and verify the selected TEE and node eligibility |
| Staged memory-policy installation omits an object | `scripts/apply-sno.sh:95` handles only documents 1–2; `gitops/base/gatekeeper/constraint-coco-mem.yaml:133` starts document 3 | Apply every constraint after CRD readiness; compare staged apply with rendered overlay |
| Proof results can survive changed inputs | `scripts/repro-loop.sh:33` and `:57` | Bind resume state to cluster, BOM, policy, references, initdata, images and test implementation |
| CI misses version-bearing paths and optional checks can disappear | `.github/workflows/scripts-ci.yml:12`, `scripts/lint.sh:26`, `scripts/test-coco-mem-rego.sh:25` | Trigger relevant changes; require pinned validators in CI and report local skips explicitly |

GitHub returned no open issues at review time. That does not mean these capabilities are complete. For example, the historical [Trustee 1.2 breakage report, issue #65][issue65], documents schema and migration failures; the active code still targets 1.1. The new work should be tracked from verified current behavior, rather than treating issue closure as feature acceptance.

## Proposed implementation sequence

### 1. Establish a release contract and strict offline checks

**Purpose:** make every later change refer to the same platform and product identities.

**Files:** new small BOM file; `install/imageset-config.yaml`; `gitops/base/operators/subscriptions.yaml`; `gitops/base/gatekeeper/operator.yaml`; `Makefile`; `ansible/group_vars/all.yml`; version-consuming scripts listed above; `.github/workflows/scripts-ci.yml`; `scripts/lint.sh`.

- Resolve exact catalog bundles and related images, including Intel prerequisites when that profile is selected. Add target-version diagnostics to the disconnected inventory.
- Check repeated digest consumers: coco-tools in VCEK/Veritas scripts, UBI in workload rendering/building, and all catalog-source references.
- Include Makefile, install, Ansible and the BOM in relevant CI triggers. Pin the required validation tools consistently on Linux/macOS.
- Validate rendered target CRs using the exact target CRD schemas. Require the existing memory Rego tests in CI. Avoid masking schema or policy errors with `|| true`.
- Preserve documented environment overrides with one clear precedence. Direct script invocation must agree with Makefile invocation.

**Acceptance:** a mismatched image/catalog/version or invalid target CR fails offline validation. All supported overlays render. Candidate BOMs and rendering can land first; activating newer catalogs, Subscriptions and defaults waits for compatible Trustee/runtime configuration and the relevant validation gates. Historical versions then remain clearly labeled rather than active defaults. Automatic InstallPlan approval must not advance the live deployment ahead of this sequence.

### 2. Repair preparation and rerun behavior

**Purpose:** prevent old artifacts from being reported as the requested new deployment.

**Files:** `scripts/install-tools.sh`; `scripts/bastion-mirror-setup.sh`; `scripts/mirror.sh`; Ansible roles `mirror_tools`, `mirror_push`, `render_configs`, `pxe_serve`, `install_drive`; baseline validation scripts.

- Replace existence-only reuse with version/input verification. Use atomic completion records only after successful operations.
- Match `openshift-install` to the mirrored release payload; reject unavailable requested tools instead of using latest.
- Invalidate mirrored inventory and generated cluster resources when the BOM/ImageSet/destination changes.
- Invalidate PXE assets when release or install inputs change. Keep sensitive assets in the operator's external state directory.
- Separate preparation, fresh install, and later upgrade modes. Display intended cluster/machine identity and operations before a mutating mode runs.
- Verify actual release and Operator identities when declaring completion.
- Preserve the DNS restart/resolution gate, external-NIC selection, mirror-auth handling, NFD operand selection and disconnected catalog protections. Remove a workaround only after a target-version test proves it unnecessary.
- Pin the existing mirror-registry bootstrap download/checksum in `infra/latitude/bastion/variables.tf:112` and `infra/latitude/bastion/cloud-init/mirror-registry.yaml:124`. Do not upgrade Terraform providers or replace the infrastructure platform without a demonstrated need.

**Acceptance:** focused offline fixtures cover old binaries, changed ImageSet with an old completion marker, changed boot inputs with existing assets, custom mirror workspace and interrupted retries. No-change repetition reuses valid artifacts; changed input cannot pass using old artifacts. A customer upgrade trace must never invoke provider reinstall.

### 3. Migrate Trustee configuration deliberately

**Purpose:** use Trustee 1.2 without losing disconnected verification or customer policy.

**Preferred maintained path:** an explicit `TrusteeConfig` profile with narrowly managed customizations to its generated resources. Default the customer profile to documented Restricted settings, HTTPS and intentional policies; reserve Permissive for the explicitly scoped disposable SNO profile. TrusteeConfig already existed in the baseline; adopting it here is repository work, not a new 1.13 feature. [Product configuration guide][trustee-config]

An initial low-level `KbsConfig` 1.2 migration remains an option if preserving the existing operational model is necessary. Choose one ownership model per deployment. Do not introduce a second controller path beside an independent KbsConfig that uses the same fixed service/deployment names.

**Migration hazard:** downstream 1.2.1 backs up/deletes unmarked configuration and policy ConfigMaps and expects TrusteeConfig reconciliation to regenerate them. The repository currently has only a manual KbsConfig. TOML migration preserves transformed plugin sections, not every customization; OfflineStore-only verifier configuration and custom policy semantics need explicit preservation. This is a source-verified risk, consistent with the older rig report, not a new hardware reproduction. Match the reviewed source to the chosen bundle and rehearse the transition. Do not manufacture migration annotations as a substitute for complete conversion. [Tagged migration implementation][migration]

**Confirmed target-format changes:**

| Surface | Current repo | Reviewed downstream 1.2.1 |
| --- | --- | --- |
| Kubernetes API | `confidentialcontainers.org/v1alpha1` | Same group/version for KbsConfig and TrusteeConfig; do not change it based on inconsistent prose examples |
| Admin/token configuration | `admin.type`, token `insecure_key` | `admin.authorization_mode`, `insecure_header_jwk`; preserve intended authorization and trust behavior |
| Resource/RVPS storage | Legacy paths and plugin configuration | Shared `storage_backend` and `kvstorage` resource plugin |
| Resource-policy ConfigMap key | `policy.rego` | `resource-policy.rego` |
| RVPS ConfigMap data | `reference-values.json` array | `reference_value` object containing encoded records |
| Resource serving | Old resource filesystem assumptions | Secret conversion into the new storage layout; verify actual refresh behavior |

Validate against the [KbsConfig CRD][kbs-crd], [TrusteeConfig CRD][trustee-crd], [Restricted TOML][restricted-toml], [Permissive TOML][permissive-toml], [controller paths][controller-common] and [resource converter][secret-converter], not a mixture of upstream latest and product examples.

**Files:** `gitops/base/trustee/*`; selected Trustee overlays; `scripts/apply-trustee.sh`; `scripts/seed-trustee-secrets.sh`; `scripts/gen-rvps-veritas.sh`; measurement/test scripts; related templates and operating guides.

- Inventory resource names, owner references, migration annotations, data-key schemas and custom rules before migration. Preserve protected backups outside the checkout.
- Render and compare the complete target configuration before applying it. Bootstrap must not overwrite an already managed reference set or policy on a rerun.
- In the rehearsed ownership transition, let the target Operator finish base migration/recreation before applying approved custom policies and OfflineStore configuration. Verify the resulting restrictions before exposing protected workload resources; otherwise migration could remove customizations just applied.
- Preserve KBS resource URIs and bytes, VCEK mounts, OfflineStore-only behavior, and customer mirror access. Separate admin authorization, HTTPS identity, attestation-token signing and workload-image signature keys.
- Choose a target-compatible Veritas/coco-tools digest; validate generated references for names, values, algorithms and expiry. Separate generation/import from publication.
- Resolve generated ConfigMap names from the deployed configuration. Update test backup/restore and policy publication for the new keys and storage format.
- Verify configuration updates and Secret rotation by observing the version actually served. A reconcile event or fixed sleep is insufficient.
- Use separate worker and Trustee contexts; render the HTTPS endpoint and trusted certificates into both attestation-agent and confidential-data-hub configuration.

**Acceptance:** no missing ConfigMaps after reconciliation; no silent loss of policy/resources; repeated apply preserves approved state; valid offline attestation and resource release work; intended policy violations deny; resource rotation and restart retain behavior. Existing-cluster migration needs its own isolated rehearsal and supported recovery plan. OLM downgrade is not assumed to be rollback.

### 4. Add an explicit disconnected Intel TDX profile

**Purpose:** exercise the product improvement most relevant to this customer's intended next test.

**Files:** NFD rules; KataConfig and workload placement; worker overlays; `scripts/apply-sno.sh`; runtime gates in rung renderers; host checks; ImageSet; Trustee certificate-cache configuration; new TDX preparation/import checks.

- Add TDX hardware and firmware prerequisites, node eligibility checks, labels and scheduling. Keep TEE-specific checks behind an explicit profile. Existing `TEE=tdx` in the Veritas wrapper is useful, but does not make the entire repo TDX-ready.
- Mirror and configure the documented Intel DCAP Operator / quote-generation path: include Intel Device Plugins Operator, the SGX device plugin, SGX/TDX NFD rules and the pinned `TdxQuoteGenerationService` configuration in `intel-dcap-operator-system`. Verify the selected release's complete disconnected requirements. [OSC 1.13 configuration][osc-config]
- Treat **platform registration/PCK provisioning** and **attestation verification collateral** as separate operations, with distinct inputs, transfer bundles and validation.
- Validate platform-data export, connected PCK provisioning, offline import and per-node quote generation as their own workflow. Select the offline provisioning mode from the supported, pinned component; upstream mechanisms are design references, not an expansion of product support. [Intel DCAP Operator][intel-dcap], [PCK tooling][intel-pck]
- Implement connected collection, transfer and offline import checks for TDX verification collateral. Record identity, collection time, expiry and refresh action. The guide describes a maximum 30-day collateral validity window; an offline success today does not establish indefinite operation. Test missing/expired collateral without relaxing the production policy. [Disconnected Trustee configuration][trustee-config]
- Assign refresh ownership and a lead time before the earliest applicable expiry; reassess platform and verifier coverage after firmware, TCB or QE changes.
- For a machine previously configured using the 1.12 TDX path, inspect the documented transition procedure, including any uninstall/SGX Factory Reset requirement. Keep firmware operations explicit and outside ordinary reruns.
- Parameterize measurement-policy rendering by actual target attestation claims. Do not reuse SNP HOST_DATA logic for TDX or mechanically replace SHA-256 with SHA-384. Confirm the deployed initdata measurement path and claim mapping using a valid control and tampered negative.

**Acceptance:** an eligible Intel node selects the expected runtime; a workload attests and retrieves its resource with external access blocked; missing/invalid/expired collateral fails for the intended reason; restoring a valid bundle restores operation. Capture quote-service health, platform provisioning state and serving collateral identity separately. AMD SNP checks remain passing.

### 5. Make the test evidence precise and reusable

**Purpose:** distinguish an actual security decision from an unrelated startup failure.

**Files:** `scripts/test-rung.sh`; `scripts/negative-test.sh`; `scripts/repro-loop.sh`; `scripts/render-measurement-policy.sh`; `scripts/encode-initdata.sh`; workload renderers; artifact-verification scripts; Gatekeeper manifests and staged application.

- Keep the measured-initdata control/tamper pair, but label it accurately. The current renderer compares `input.init_data` to a literal digest; it does not demonstrate use of generated RVPS launch references.
- Preserve the target policy's collateral-validity, TCB and other checks when adding initdata binding. Do not carry forward the current renderer's default affirmation of unrelated trust categories.
- Add an independent RVPS proof: fixed workload/policy, approved references allow, wrong/missing/expired launch references deny where required by that policy, restored references allow again. Validate relevant firmware/TCB claims separately. Inspect the complete [target CPU policy][cpu-policy].
- Produce one canonical initdata artifact and derive encoding, measured digest and policy from those exact bytes. Record the selected vendor Kata Agent policy or a complete tested restrictive replacement; omission of a custom policy is not by itself proof that the packaged default is permissive.
- Require positive controls before accepting negative results. Correlate denial evidence to the tested pod/session and configuration revision. DNS failure, invalid image naming, KBS outage, registry transport failure or a generic log containing “signature” must not count as signature rejection.
- Retain signed-image testing with the customer's actual signature storage/registry behavior. Local signature verification proves artifact preparation; it does not prove verification in the confidential guest.
- Make pass/fail/incomplete/not-applicable results structured. Every mandatory proof must execute successfully. A skipped encrypted-image test must remain visible and cannot support a broader “all capabilities proven” claim.
- Bind resume state to cluster identity, source revision, BOM, TEE, initdata, references, policy and image digests. Invalidate previous passes when any relevant input changes.
- Isolate policy/certificate fault injection in a disposable validation environment. Avoid mutating all shared `vcek-*` Secrets. Restoration must preserve full relevant state, be verified, and fail the run if incomplete.
- Apply every memory-constraint document. The unlabeled constraint is currently `dryrun`; installing it does not establish enforcement. Verify ordinary pods remain unaffected, labeled/unlabeled CoCo handling, init and multi-container accounting, chosen request/limit behavior, and actual VM overhead before selecting enforcement. Do not market a static memory default as a complete sizing solution.

**Acceptance:** synthetic offline harness cases reject unrelated failures, stale passes and failed restoration. Later hardware runs show paired allow/deny/recovery results for each claimed capability with attributable evidence.

### 6. Make maintenance and the operator workflow explicit

**Purpose:** make the next failure diagnosable without repeating the initial investigation.

**Files:** Makefile; validation scripts; `docs/getting-started-and-operations.md`; install/bring-up/runbook guides; `docs/research/workflow-automation-map.md`; customer Artifactory examples; a small evidence collector if needed.

Expose a consistent sequence through the existing tools:

1. Select release/TEE/topology and validate local inputs.
2. Prepare and verify the disconnected artifact bundle.
3. Check worker and Trustee prerequisites using their explicit contexts.
4. Collect/import required endorsements before applying configuration that needs them.
5. Deploy the platform/Trustee base, finish Operator reconciliation, and verify actual versions, endpoint and trust configuration.
6. Render and freeze the exact workload/initdata set; generate/import matching Veritas references, publish RVPS and approved policies/resources, verify the serving configuration, then admit the workload.
7. Run named proofs and produce a concise result report with precise gaps.
8. Explain refresh and recovery actions for references, endorsements, resources and certificates.

Preflight output should identify the failing dependency, expected state and next action before long deployment steps. A status report should distinguish transport, attestation, token verification, resource-policy and image-policy failures. Preserve the useful diagnosis already in `debug-surface.md`.

Record non-secret provenance with each run: source SHA, actual platform/Operator/operand identities, TEE/node identity, configuration hashes, collateral expiry, initdata/reference/policy identifiers, expected/observed decisions and restoration status. Diagnostic archives can contain sensitive information and must use protected external storage.

OCP/OSC changes can require new reference values. Follow the product-specific update order and regenerate/reapply references at the documented points; do not infer this from Operator availability alone. [OSC update procedure][osc-update], [Trustee update procedure][trustee-update]

For AMD, verify endorsement coverage against actual eligible hardware identities and TCBs. The gist's historical per-socket count and later per-host documentation are not a substitute for evidence on the customer's multi-socket machines.

**Acceptance:** the active guide follows executable order and the selected version/profile. A second operator can identify a missing prerequisite or expired artifact from the report. Historical 1.12 findings stay labeled; no stale “RVPS skipped” or unsupported “all proven” claims remain in the active workflow.

## Validation stages and dependencies

| Stage | Required evidence | Dependency / boundary |
| --- | --- | --- |
| Offline baseline, completed in this review | Shell syntax, endpoint/label checks, four overlay renders, ShellCheck | Existing code only; limited evidence below |
| Release and static migration validation | Exact BOM, target schemas, strict policy tests, state-invalidation fixtures, rendering of AMD/TDX profiles | Packages 1–2; can proceed alongside Trustee/TDX implementation |
| Fresh AMD target-version rehearsal | Cold installation, offline attestation/resource release, precise allow/deny proofs | Trustee migration and test corrections; authorized disposable hardware |
| Rerun and interrupted-run rehearsal | No-change convergence, correct invalidation, safe resumption and restoration | Same rig where possible; do not add unnecessary reinstalls |
| Fresh disconnected Intel rehearsal | Provisioning/quote health, valid and expired/missing collateral behavior, measured-initdata and reference proofs | Intel-capable hardware plus profile and collateral workflow |
| Existing-cluster upgrade rehearsal | Supported before/after path, preserved customizations/resources, runtime update effects, regenerated references and recovery proof | Separately inventoried baseline; never the fresh-install entry point |
| Customer-topology rehearsal | Separate Trustee context/HTTPS, multiple eligible workers, actual registry/signature behavior | Explicit customer inputs; SNO evidence alone is insufficient |

Do not make hardware success a prerequisite for useful offline implementation. Do make it a prerequisite for claims that the new deployment, migration or security property is proven.

## Encrypted images and other deferred work

Encrypted images remain a separately tracked capability, not an acceptance promise for this update. Upstream [CRI-O PR #9907][crio-upstream] merged on August 28, 2026. The inspected downstream [OpenShift PR #82][crio-downstream] was still open on October 2 and targets `release-5.0`. This does not establish delivery in the planned OCP 4.20–4.22 payloads or this bare-metal runtime. Revisit only when a supported payload and successful guest-side proof are available. Encrypted block volumes are a different capability.

Also defer GPU support, replacement of the infrastructure provider, adoption of an entire alternative platform pattern, and a generalized production governance framework. None is needed to answer whether this customer's CPU-only evaluation has become easier to deploy and operate.

## What would be worth demonstrating after validation

1. **Disconnected TDX attestation:** healthy Intel quote generation, offline collateral, successful resource release, then a targeted denial and recovery. This directly addresses the customer's intended Intel test.
2. **A reliable rerun:** show that unchanged inputs converge, a changed input invalidates only the affected work, and missing collateral is reported before workload debugging starts. Identify these as improvements to the example tooling.
3. **A truthful policy proof:** approved workload and references run; tampered initdata or wrong references deny; approved state restores service. Include signed-image accept/reject only once the selected registry/guest path is verified. Signing itself is not new in OSC 1.13.

For Monday, an untested workflow should be presented as a proposal or diagram, not as a completed live capability. Keep remaining maintenance burden visible alongside product improvements.

## Review verification and remaining decisions

Executed locally, without cluster access:

- `bash scripts/lint.sh`: passed shell syntax, endpoint parameterization, workload-label checks, and all four overlay renders via `oc kustomize`.
- `shellcheck --severity=warning -x scripts/*.sh scripts/lib/*.sh`: passed with ShellCheck 0.11.0.
- Rego tests were explicitly skipped because OPA is unavailable. kubeconform and conftest are unavailable; target-schema and policy validation were not established.
- Render tooling: OpenShift client release 4.21.15, embedded Kustomize v5.7.1, Bash 5.3.9. No macOS validation, Ansible execution, images pulled, cloud infrastructure created, hardware checks or deployment tests were performed.
- Main was clean before this planning document. No implementation files were changed.

Resolve during implementation planning: exact catalog/payload identities and upgrade graph; hardware availability for Intel; actual worker/Trustee topology and customer registry; current deployed configuration inventory; chosen Trustee ownership transition; required maintenance/recovery procedure. These do not prevent the offline preparation and test work described above.

[matrix]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/cc-discover_metal-cc
[osc-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc
[trustee-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/configure-trustee-overview_metal-trustee-disconnected
[osc-update]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/update-osc-cc-overview_metal-cc-update
[trustee-update]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/update-trustee-overview_metal-trustee-disconnected
[issue65]: https://github.com/shpwrck/openshift-confidential-containers/issues/65
[migration]: https://github.com/openshift/trustee-operator/blob/v1.2.1/internal/controller/migration.go
[kbs-crd]: https://github.com/openshift/trustee-operator/blob/v1.2.1/bundle/manifests/confidentialcontainers.org_kbsconfigs.yaml
[trustee-crd]: https://github.com/openshift/trustee-operator/blob/v1.2.1/bundle/manifests/confidentialcontainers.org_trusteeconfigs.yaml
[restricted-toml]: https://github.com/openshift/trustee-operator/blob/v1.2.1/config/templates/kbs-config-restricted.toml
[permissive-toml]: https://github.com/openshift/trustee-operator/blob/v1.2.1/config/templates/kbs-config-permissive.toml
[controller-common]: https://github.com/openshift/trustee-operator/blob/v1.2.1/internal/controller/common.go
[secret-converter]: https://github.com/openshift/trustee-operator/blob/v1.2.1/cmd/secret-converter/main.go
[cpu-policy]: https://github.com/openshift/trustee-operator/blob/v1.2.1/config/templates/ear_default_attestation_policy_cpu.rego
[crio-upstream]: https://github.com/cri-o/cri-o/pull/9907
[crio-downstream]: https://github.com/openshift/cri-o/pull/82
[intel-dcap]: https://github.com/intel/confidential-computing.tee.dcap.k8s.qgs/blob/main/bin/operator/README.md
[intel-pck]: https://github.com/intel/confidential-computing.tee.dcap.k8s.qgs/blob/main/bin/pck-cert-tool/README.md
