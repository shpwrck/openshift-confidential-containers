# MA01-MA03 artifact specification links

Research date: **2026-08-26**

| Boundary | Value |
|---|---|
| Product baseline | OpenShift sandboxed containers (OSC) 1.12; Red Hat build of Trustee 1.1 |
| Deployment | Disconnected AMD SEV-SNP bare metal; local `kata-cc`; Trustee on a separate trusted OpenShift cluster |
| Excluded | Remote deployment modes and OSC 1.13 / Trustee 1.2 procedures or schemas |
| Purpose | Primary-source links and minimum field guidance for MA01, MA02, and MA03 in the operating playbook |

This is a research aid, not another product procedure. Red Hat's versioned documentation and the CRDs
installed on the target clusters are authoritative for supported behavior. Upstream documents explain
formats and design; they do not expand Red Hat support. A link to a rolling upstream `main` page must
be revalidated against the binaries in the frozen bill of materials.

## Findings that affect the artifact appendix

1. **MA01 does not currently describe the local GitOps base literally.** Red Hat 1.12 says to use a
   `TrusteeConfig` as the starting point, use `Restricted` for production, and reserve direct
   `KbsConfig` management for advanced customization. The local base instead applies a low-level
   [`KbsConfig`](../../gitops/base/trustee/kbsconfig.yaml) and its base
   [AS and KBS policies are permissive](../../gitops/base/trustee/kbs-configmaps.yaml). Do not label
   that base a Restricted `TrusteeConfig`. Either produce the actual Restricted `TrusteeConfig` and
   generated-resource snapshot, or record an approved advanced-configuration exception and include
   the `KbsConfig`, all referenced objects, the installed CRD, and the equivalent enforced controls.
   [Red Hat's disconnected Trustee 1.1 configuration chapter][rh-trustee-config] is the product
   authority.
2. **MA02 requires an explicit trust decision for the Kata Agent policy.** Red Hat 1.12 says a custom
   policy replaces the default in full, warns against a permissive production policy, and requires at
   least `ExecProcessRequest` to be disabled. The local
   [initdata example](../../gitops/base/workloads/initdata.example.toml) deliberately omits
   `policy.rego` to use the guest's complete built-in policy. That is not enough evidence for MA02's
   phrase “restrictive Kata Agent policy.” The bundle must contain either the complete applied policy
   and its digest or an exact vendor guest-asset/default-policy identity plus a tested proof that the
   required operations are denied. [Red Hat bare-metal configuration][rh-cc-config] governs this
   baseline; [upstream Kata policy documentation][kata-policy] is explanatory.
3. **MA03 names controls absent from the local workload examples.** The rung Pods run in `default`,
   do not set `serviceAccountName`, and do not express workload placement. Red Hat 1.12 directs users
   to create a dedicated workload namespace. MA03 should therefore require dedicated `Namespace` and
   `ServiceAccount` manifests plus effective placement, not merely accept the current examples.
4. **Generated objects and source objects are different evidence.** The OSC Operator creates
   `RuntimeClass/kata-cc`; it should normally be captured from the live cluster, not independently
   authored. Likewise, `TrusteeConfig` generates `KbsConfig`, ConfigMaps, and Secrets. Retain both the
   desired source and the observed generated resources, with content hashes and the installed CSV/CRD
   versions.
5. **Some local implementation assertions are intentionally unverified.** In particular,
   [`render-measurement-policy.sh`](../../scripts/render-measurement-policy.sh) says its initdata hash
   mapping must be confirmed against real attestation evidence, and the VCEK tooling contains
   multi-socket handling beyond the one-node workflow in the Red Hat guide. Preserve these as test or
   support-case gates rather than turning comments into product requirements.

## MA01 — Trustee baseline bundle

The baseline is a versioned declaration of **what Trustee trusts, what it may release, and which
endorsement material it can use**. Store configuration and metadata in Git; store private keys and
resource values only in the approved secret/backup system.

| Required item | Minimum machine-readable contents | Primary specification / product source | Concrete local implementation |
|---|---|---|---|
| Product and schema identity | OCP z-stream, OSC CSV/image digest, Trustee CSV/image digest, retrieval time, exported installed `TrusteeConfig` and `KbsConfig` CRDs | [OSC 1.12 release notes][rh-release]; [Red Hat Trustee 1.1 configure][rh-trustee-config]; upstream point-in-time [TrusteeConfig CRD][up-trusteeconfig-crd] and [KbsConfig CRD][up-kbsconfig-crd] are comparison aids only | [`subscriptions.yaml`](../../gitops/base/operators/subscriptions.yaml) pins OSC 1.12.1 and Trustee 1.1.0 |
| Desired Trustee root | Full `TrusteeConfig` YAML, `profileType: Restricted`, service exposure, HTTPS Secret ref, token-verification trust ref, owner and Git revision | Red Hat's [TrusteeConfig field reference and Restricted example][rh-trustee-config] | **Gap:** no local `TrusteeConfig`; [`kbsconfig.yaml`](../../gitops/base/trustee/kbsconfig.yaml) is the advanced path |
| Generated/advanced deployment | Full observed `KbsConfig`; every referenced ConfigMap/Secret name and key; deployment type, service type, replicas, storage and certificate-cache mounts; owner and content digest | [Red Hat customization of autogenerated resources][rh-trustee-config]; upstream point-in-time [KbsConfig CRD][up-kbsconfig-crd] | [`kbsconfig.yaml`](../../gitops/base/trustee/kbsconfig.yaml) and [`kbs-configmaps.yaml`](../../gitops/base/trustee/kbs-configmaps.yaml) |
| KBS runtime and administrative trust | Redacted `kbs-config.toml`, HTTPS mode and certificate identity, admin mode, public admin key or token trust reference, token signing/verification mode, enabled plugins, resource backend, policy path; never the private key | [Upstream KBS configuration][trustee-kbs-config]; [KBS administrative and resource protocol][trustee-kbs-protocol] | `kbs-config` in [`kbs-configmaps.yaml`](../../gitops/base/trustee/kbs-configmaps.yaml); Secret conventions in [`secret-stubs.example.yaml`](../../gitops/base/trustee/secret-stubs.example.yaml) |
| AS policy | Complete applied CPU policy, ConfigMap name/key, SHA-256, Git revision, policy engine, intended claim mapping, approver, effective/expiry time, positive and negative test IDs | [Red Hat generated AS policy and customization][rh-trustee-config]; upstream [Trustee policy model][coco-policies] and point-in-time [AS policy sample][up-as-policy] | `attestation-policy/default_cpu.rego` in [`kbs-configmaps.yaml`](../../gitops/base/trustee/kbs-configmaps.yaml); restrictive renderer in [`render-measurement-policy.sh`](../../scripts/render-measurement-policy.sh) |
| KBS resource policy | Complete applied policy, ConfigMap name/key, SHA-256, exact resource paths governed, token claims required, default-deny behavior, approver, effective/expiry time, allow/deny evidence IDs | [Red Hat generated resource policy and customization][rh-trustee-config]; upstream [policy semantics][coco-policies], [resource URI model][coco-resources], and point-in-time [resource policy sample][up-resource-policy] | `resource-policy/policy.rego` in [`kbs-configmaps.yaml`](../../gitops/base/trustee/kbs-configmaps.yaml) |
| RVPS/reference values | Exact `reference-values.json`, ConfigMap name/key, SHA-256, revision, platform/measurement names, algorithm/value, source/provenance, validity, approver, and the AS policy revision that consumes them | [Red Hat RVPS generation procedure][rh-trustee-config]; upstream [reference-value concepts][coco-reference-values] and point-in-time [RVPS sample][up-rvps-sample] | `rvps-reference-values` in [`kbs-configmaps.yaml`](../../gitops/base/trustee/kbs-configmaps.yaml); [`gen-rvps-veritas.sh`](../../scripts/gen-rvps-veritas.sh) |
| Protected resource catalog | KBS URI (`kbs:///<repository>/<type>/<tag>`), backing Secret name/key, data owner, purpose, classification, consumer policy revision, key/version identifier, created/rotated/expires timestamps, backup reference; no plaintext or reusable key bytes | [Red Hat `kbsSecretResources` and signature-resource procedures][rh-trustee-config]; upstream [resource identifiers][coco-resources] and [KBS protocol paths][trustee-kbs-protocol] | [`secret-stubs.example.yaml`](../../gitops/base/trustee/secret-stubs.example.yaml); [`seed-trustee-secrets.sh`](../../scripts/seed-trustee-secrets.sh) |
| AMD VCEK offline cache | Covered node, socket/chip/HWID, processor generation, firmware/TCB parameters, source URL, DER SHA-256, certificate issuer/serial/validity, collection tool/version/time, Secret name/key, mount path, validation result, and refresh trigger | [Red Hat 1.12 disconnected VCEK procedure][rh-trustee-config]; upstream point-in-time [offline VCEK cache layout and invalidation events][trustee-vcek-cache]; [AMD SEV-SNP ABI specification][amd-snp-abi] | [`collect-vcek.sh`](../../scripts/collect-vcek.sh), [`seed-trustee-secrets.sh`](../../scripts/seed-trustee-secrets.sh), and `kbsLocalCertCacheSpec` in [`kbsconfig.yaml`](../../gitops/base/trustee/kbsconfig.yaml) |
| Backup references | Backup-set ID, encrypted location, captured CR/ConfigMap/Secret/backend inventory, excluded/generated items, encryption-key custodian, restore order, RPO/RTO, last restore test and post-restore allow/deny evidence; keep the backup itself out of Git | Kubernetes [ConfigMap][k8s-configmap] and [Secret][k8s-secret] schemas define the objects, but the reviewed Red Hat Trustee chapter does not supply an end-to-end DR schema | Link to the separately approved HA09 backup/recovery record; do not invent a fake in-repo secret backup |

### MA01 acceptance rules

- A policy file without its exact digest, approver, dependent reference-value revision, and denial
  test is not a production baseline.
- `Restricted` is a `TrusteeConfig` profile value, not a label to attach to an arbitrary set of
  hand-built ConfigMaps.
- The Red Hat guide's VCEK procedure and the local multi-socket procedure differ in granularity.
  For multi-socket hosts, require live negative/positive evidence for every launch location and seek
  Red Hat confirmation before claiming the local per-chip cache scheme is the supported contract.
- An empty RVPS array and `default allow := true` are evaluation scaffolding, not production MA01.

## MA02 — workload trust bundle

The bundle identifies **exactly what will run, how its publisher and contents are checked, which
launch configuration is measured, and which protected dependencies it can request**. It should be a
small signed metadata document that points to immutable artifacts rather than copying secret values.

| Required item | Minimum machine-readable contents | Primary specification / product source | Concrete local implementation |
|---|---|---|---|
| OCI workload identity | Fully qualified repository plus manifest digest (`@sha256:...`), platform, manifest media type/size, registry/mirror identity, build ID, creation time, and verification result | OCI Image Spec 1.1.1 [descriptor and digest rules][oci-descriptor], [manifest subject/artifact rules][oci-manifest], and [Distribution Spec 1.1.1][oci-distribution] | Digest-pinned exemplar in [`rung-a-secret-pod.yaml`](../../gitops/base/workloads/rung-a-secret-pod.yaml); signed/encrypted templates are rendered by scripts before use |
| SBOM | SBOM format/version, SBOM digest and immutable location, image subject digest, generator/version/time, completeness scope, vulnerability-scan reference | OSC does not prescribe an MA02 SBOM schema. Use an approved standard such as [SPDX 3.0.1][spdx] and bind it to the OCI subject digest | **Gap:** no SBOM artifact is produced by the current rung image script |
| Provenance | Attestation format/version, statement digest/location, image subject digest, builder identity, build type, source/material digests, parameters, build time, verification policy/result | [in-toto Attestation Framework v1][in-toto] and [SLSA Provenance v1.0][slsa]; these are supply-chain standards, not OSC support statements | **Gap:** [`build-rung-images.sh`](../../scripts/build-rung-images.sh) records build outputs but not standardized provenance |
| Signature evidence | Signed image digest, signature/bundle reference and digest, signing scheme, public-key or certificate identity, signer identity, signing/verification tool versions, policy revision, verification time/result, and negative-test result | [Red Hat Trustee signature key and image policy procedures][rh-trustee-config]; [containers/image policy schema][containers-policy]; [Cosign signature payload spec][cosign-spec] for the local scheme | [`build-rung-images.sh`](../../scripts/build-rung-images.sh), [`verify-rung-signed-signature.sh`](../../scripts/verify-rung-signed-signature.sh), and `sig-public-key` conventions in [`secret-stubs.example.yaml`](../../gitops/base/trustee/secret-stubs.example.yaml) |
| Encryption evidence, when used | Encrypted manifest digest, source/plain image digest where policy permits retaining it, encryption/key-provider tool versions, layer encryption annotation/key ID, KBS resource URI, key version/rotation owner, decrypt allow/deny evidence; never the raw decryption key | Upstream [CoCo encrypted-image workflow][coco-encrypted] and [ocicrypt implementation contract][ocicrypt]; OCI descriptor/manifest rules remain the content-addressing base | [`build-rung-images.sh`](../../scripts/build-rung-images.sh), [`verify-rung-encrypted-key-wrap.sh`](../../scripts/verify-rung-encrypted-key-wrap.sh), and `kbs:///default/image-key/rung-encrypted` in [`secret-stubs.example.yaml`](../../gitops/base/trustee/secret-stubs.example.yaml) |
| Initdata source and binding | Exact rendered source bytes, format version, declared hash algorithm, source SHA-256, encoded annotation SHA-256, KBS URL, certificate fingerprints, included file names, applied Pod annotation, expected SNP HOST_DATA / attestation claim, AS/RVPS revision, and match/mismatch test IDs | [Red Hat 1.12 initdata creation, hashing, application, and attestation][rh-cc-config]; upstream point-in-time [initdata specification][trustee-initdata] | [`initdata.example.toml`](../../gitops/base/workloads/initdata.example.toml), [`encode-initdata.sh`](../../scripts/encode-initdata.sh), and [`render-measurement-policy.sh`](../../scripts/render-measurement-policy.sh) |
| Restrictive Kata Agent policy | Complete applied `policy.rego`, SHA-256, source/generator and version, request rules, explicit `ExecProcessRequest` result, approved operational exceptions, Pod/initdata binding, and allow/deny evidence. If relying on a vendor default, identify the exact guest asset and extracted policy digest | [Red Hat 1.12 production requirement and complete-policy warning][rh-cc-config]; upstream [Kata Agent policy and `genpolicy` behavior][kata-policy] | **Gap:** [`initdata.example.toml`](../../gitops/base/workloads/initdata.example.toml) omits `policy.rego`; a complete tested policy must be added to the bundle or the exact built-in policy evidenced |
| Dependency list | Every image pulled inside the CVM (application, init, pause/release/helper), each digest/signature requirement; KBS resource URIs; registry remaps; CA fingerprints; storage/PVCs; network destinations/ports; referenced policies and owners | Red Hat [initdata/image policy and workload configuration][rh-cc-config]; upstream point-in-time [CDH image configuration fields][guest-cdh-config] | [`rung-a-secret-pod.yaml`](../../gitops/base/workloads/rung-a-secret-pod.yaml), [`initdata.example.toml`](../../gitops/base/workloads/initdata.example.toml), and dependency handling in [`seed-trustee-secrets.sh`](../../scripts/seed-trustee-secrets.sh) |

### MA02 acceptance rules

- A tag is a discovery aid, not the released identity. The Pod and bundle must use the resolved
  manifest digest.
- Initdata provides integrity binding, not confidentiality. Upstream explicitly says the untrusted
  host can see it; do not put passwords, private keys, tokens, or plaintext protected resources in it.
- Image encryption and image signing prove different properties. When both controls are required,
  retain evidence for both and bind both to the same immutable image identity.
- A Cosign “verified” console line without the subject digest, public-key identity, policy revision,
  tool version, and retained result is not durable signature evidence.

## MA03 — platform deployment set

The deployment set is the exact desired OpenShift configuration that **makes eligible nodes expose
`kata-cc` and makes only the intended workloads select it**. Keep operator-owned generated objects as
observed evidence unless Red Hat explicitly directs the administrator to edit them.

| Required item | Minimum machine-readable contents | Primary specification / product source | Concrete local implementation |
|---|---|---|---|
| Operator installation identity | Namespaces, OperatorGroups, Subscriptions, channels, CatalogSource, approval mode, starting CSV, installed CSV and image digests | [Red Hat OSC 1.12 installation/configuration guide][rh-cc-guide] and [release notes][rh-release] | [`namespaces.yaml`](../../gitops/base/operators/namespaces.yaml), [`operatorgroups.yaml`](../../gitops/base/operators/operatorgroups.yaml), [`subscriptions.yaml`](../../gitops/base/operators/subscriptions.yaml) |
| TEE discovery | Full `NodeFeatureDiscovery` and `NodeFeatureRule`; NFD operand identity; exact SNP label and ESID extended resource; effective matching-node inventory | [Red Hat 1.12 TEE auto-detection and CR examples][rh-cc-config]; upstream rolling [NFD CR/API reference][nfd-api]; OSC 1.12.1 [AMD rule source][osc-amd-rule] | [`nodefeaturediscovery.yaml`](../../gitops/base/nfd/nodefeaturediscovery.yaml) and [`amd-snp-rule.yaml`](../../gitops/base/nfd/amd-snp-rule.yaml) |
| CoCo feature gate | `ConfigMap/osc-feature-gates`, namespace, `confidential: "true"`, effective deployment mode/default, applied-before-KataConfig evidence | [Red Hat 1.12 enabling procedure][rh-cc-config]; OSC 1.12.1 [feature-gate sample][osc-featuregate] | [`feature-gates.yaml`](../../gitops/base/kataconfig/feature-gates.yaml) |
| Kata installation | Full `KataConfig`, target pool selector, eligibility setting, status/conditions, node reboot/change evidence, installed CRD and CSV | [Red Hat 1.12 KataConfig procedure][rh-cc-config]; OSC 1.12.1 [KataConfig CRD][osc-kataconfig-crd] | [`kataconfig.yaml`](../../gitops/base/kataconfig/kataconfig.yaml) |
| Generated runtime evidence | Exported live `RuntimeClass/kata-cc`: handler, overhead, scheduling selector/tolerations, object UID/resourceVersion, creation time and owning OSC version; eligible-node resolution test | Kubernetes [RuntimeClass API][k8s-runtimeclass] and [runtime selection/overhead semantics][k8s-runtimeclass-concept]; Red Hat identifies `kata-cc` as the bare-metal confidential runtime | Operator-generated; verify rather than add a hand-authored base manifest |
| Dedicated workload identity | Dedicated `Namespace`, `ServiceAccount`, RBAC bindings, image-pull identity where used, labels/annotations, owners; `automountServiceAccountToken: false` unless the application requires Kubernetes API access | Kubernetes [Namespace][k8s-namespace] and [ServiceAccount][k8s-serviceaccount] APIs; Red Hat 1.12 says not to deploy in an Operator namespace and to create a dedicated namespace | **Gap:** rung Pods use `default` and implicit default ServiceAccount |
| Pod/workload template | Controller or Pod kind; `serviceAccountName`; `runtimeClassName: kata-cc`; digest-pinned images; initdata annotation; requests/limits; security context; restart/update strategy; dependency labels and bundle revision | Kubernetes [Pod API][k8s-pod]; Red Hat [workload and initdata procedures][rh-cc-config] | [`rung-a-secret-pod.yaml`](../../gitops/base/workloads/rung-a-secret-pod.yaml), [`rung-signed-pod.yaml`](../../gitops/base/workloads/rung-signed-pod.yaml), [`rung-encrypted-pod.yaml`](../../gitops/base/workloads/rung-encrypted-pod.yaml) |
| Placement and capacity | Pod and RuntimeClass node selectors/affinity, taints/tolerations, topology constraints, KataConfig pool selector, effective nodes, SNP ESID availability, requested/limited CPU/memory, observed RuntimeClass overhead | Kubernetes [Pod][k8s-pod] and [RuntimeClass scheduling/overhead][k8s-runtimeclass-concept]; Red Hat warns that supported default overhead values should not be changed casually | **Gap for multi-node production:** local base leaves `kataConfigPoolSelector` unset and workload Pods have no explicit placement |
| Storage and network | PVC/volume manifests and modes, encryption mechanism/key reference, StorageClass/CSI support decision, NetworkPolicies and required egress matrix, DNS/TLS/registry/KBS destinations, ports and certificate fingerprints | Kubernetes [PVC][k8s-pvc] and [NetworkPolicy][k8s-networkpolicy] APIs; storage design must use the OSC 1.12 bare-metal product procedure when applicable | No complete workload-specific storage/network set is present in the rung Pod examples; MA03 must point to the approved overlays |

### MA03 acceptance rules

- A Pod being `Running` is insufficient. Retain its UID, node, `runtimeClassName`, resolved image
  digest, initdata digest, live `RuntimeClass/kata-cc`, and the matching MA01/MA02 revisions.
- Do not create or edit `RuntimeClass/kata-cc` merely to make a manifest validate. It is evidence that
  the OSC/KataConfig reconciliation succeeded; unsupported overhead edits can invalidate the product
  baseline.
- `runtimeClassName: kata-cc` selects the runtime. It does not by itself prove attestation, policy
  appraisal, signature verification, or resource authorization; those results belong in HA07 and
  reference MA01/MA02.

## Recommended artifact envelope

Each MA bundle should have a small top-level metadata file so approvals and evidence can refer to an
immutable revision without parsing every YAML file:

```yaml
apiVersion: operating-playbook.example/v1alpha1
kind: ArtifactBundle
metadata:
  id: MA01 # MA02 or MA03
  revision: "<content-addressed or signed revision>"
  createdAt: "<RFC3339>"
  owners: ["<team-or-role>"]
spec:
  productBaseline:
    ocp: "<z-stream>"
    oscCSV: "<CSV and image digest>"
    trusteeCSV: "<CSV and image digest>"
  files:
    - path: "<relative-path>"
      sha256: "<64 lowercase hex characters>"
      purpose: "<what this file controls or proves>"
  dependencies:
    - id: "<MA/HA ID or external immutable artifact>"
      revision: "<revision or digest>"
  approvals:
    - role: "<decision owner>"
      evidenceRef: "<signed change/approval record>"
  verification:
    - control: "<allow or deny behavior>"
      evidenceRef: "<HA07 record location>"
```

`operating-playbook.example/v1alpha1` is a documentation convention proposed for this repository,
not a Kubernetes or Red Hat API. Validate it with a repository-owned JSON Schema before automation.

## Source catalog and version caveats

### Red Hat product authority for this baseline

- [OSC 1.12 bare-metal Confidential Containers guide][rh-cc-guide] — support boundary, prerequisites,
  `kata-cc`, NFD, feature gate, `KataConfig`, initdata, workload, operations.
- [OSC 1.12 bare-metal configuration chapter][rh-cc-config] — the primary field/procedure page for
  MA02 and MA03.
- [OSC 1.12 disconnected Trustee guide][rh-trustee-guide] and
  [configuration chapter][rh-trustee-config] — `TrusteeConfig`, Restricted profile, generated
  resources, KbsConfig customization, VCEK, image policy, RVPS, and verification.
- [OSC 1.12 release notes][rh-release] — confirms the 1.12 feature set and Trustee 1.1 recommendation.

Red Hat pages can be corrected in place. Retain a dated PDF or approved change-record snapshot for
each production baseline; do not infer that an upstream tag is the source-equivalent of a Red Hat
container unless Red Hat publishes that mapping.

### Upstream formats and implementation references

- Trustee/CoCo: [architecture][coco-architecture], [policies][coco-policies],
  [reference values][coco-reference-values], [resources][coco-resources],
  [KBS configuration][trustee-kbs-config], [KBS protocol][trustee-kbs-protocol],
  [initdata specification][trustee-initdata], and [offline VCEK cache][trustee-vcek-cache].
- Workload trust: OCI [descriptor][oci-descriptor], [manifest][oci-manifest], and
  [distribution][oci-distribution]; [containers/image policy][containers-policy];
  [Cosign payload][cosign-spec]; [ocicrypt][ocicrypt]; [SPDX][spdx]; [in-toto][in-toto];
  [SLSA provenance][slsa].
- Platform API: Kubernetes [Pod][k8s-pod], [RuntimeClass][k8s-runtimeclass],
  [Namespace][k8s-namespace], [ServiceAccount][k8s-serviceaccount], [ConfigMap][k8s-configmap],
  [Secret][k8s-secret], [PVC][k8s-pvc], and [NetworkPolicy][k8s-networkpolicy].

Pinned upstream `v0.19.0` and OSC `v1.12.1` GitHub links provide stable comparison points. The
Trustee upstream version is **not asserted to equal Red Hat Trustee 1.1**. The live installed CRDs
and Red Hat 1.12 documentation win if a field differs.

[amd-snp-abi]: https://docs.amd.com/api/khub/documents/NJQrpYY7KZGtlxDEdBGtzA/content
[coco-architecture]: https://confidentialcontainers.org/docs/attestation/architecture/
[coco-encrypted]: https://confidentialcontainers.org/docs/features/encrypted-images/
[coco-policies]: https://confidentialcontainers.org/docs/attestation/policies/
[coco-reference-values]: https://confidentialcontainers.org/docs/attestation/reference-values/
[coco-resources]: https://confidentialcontainers.org/docs/attestation/resources/
[containers-policy]: https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
[cosign-spec]: https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md
[guest-cdh-config]: https://github.com/confidential-containers/guest-components/blob/v0.19.0/confidential-data-hub/example.config.toml
[in-toto]: https://github.com/in-toto/attestation/tree/main/spec/v1
[kata-policy]: https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-the-kata-agent-policy.md
[k8s-configmap]: https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/config-map-v1/
[k8s-namespace]: https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/namespace-v1/
[k8s-networkpolicy]: https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
[k8s-pod]: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/
[k8s-pvc]: https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-claim-v1/
[k8s-runtimeclass-concept]: https://kubernetes.io/docs/concepts/containers/runtime-class/
[k8s-runtimeclass]: https://kubernetes.io/docs/reference/kubernetes-api/node/runtime-class-v1/
[k8s-secret]: https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/secret-v1/
[k8s-serviceaccount]: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/service-account-v1/
[nfd-api]: https://kubernetes-sigs.github.io/node-feature-discovery/master/reference/generated-nfd-api-reference.html
[oci-descriptor]: https://github.com/opencontainers/image-spec/blob/v1.1.1/descriptor.md
[oci-distribution]: https://github.com/opencontainers/distribution-spec/blob/v1.1.1/spec.md
[oci-manifest]: https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md
[ocicrypt]: https://github.com/containers/ocicrypt/blob/main/README.md
[osc-amd-rule]: https://github.com/openshift/sandboxed-containers-operator/blob/v1.12.1/scripts/install-helpers/baremetal-coco/nfd/amd-rules.yaml
[osc-featuregate]: https://github.com/openshift/sandboxed-containers-operator/blob/v1.12.1/config/samples/featuregates.yaml
[osc-kataconfig-crd]: https://github.com/openshift/sandboxed-containers-operator/blob/v1.12.1/config/crd/bases/kataconfiguration.openshift.io_kataconfigs.yaml
[rh-cc-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc
[rh-cc-guide]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/index
[rh-release]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/release_notes/index
[rh-trustee-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/configure-trustee-overview_metal-trustee-disconnected
[rh-trustee-guide]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/index
[slsa]: https://slsa.dev/spec/v1.0/provenance
[spdx]: https://spdx.github.io/spdx-spec/v3.0.1/
[trustee-initdata]: https://github.com/confidential-containers/trustee/blob/v0.19.0/kbs/docs/initdata.md
[trustee-kbs-config]: https://github.com/confidential-containers/trustee/blob/v0.19.0/kbs/docs/config.md
[trustee-kbs-protocol]: https://github.com/confidential-containers/trustee/blob/v0.19.0/kbs/docs/kbs_attestation_protocol.md
[trustee-vcek-cache]: https://github.com/confidential-containers/trustee/blob/v0.19.0/attestation-service/docs/amd-offline-certificate-cache.md
[up-as-policy]: https://github.com/confidential-containers/trustee-operator/blob/v0.19.0/config/samples/all-in-one/attestation-policy.yaml
[up-kbsconfig-crd]: https://github.com/confidential-containers/trustee-operator/blob/v0.19.0/config/crd/bases/confidentialcontainers.org_kbsconfigs.yaml
[up-resource-policy]: https://github.com/confidential-containers/trustee-operator/blob/v0.19.0/config/samples/all-in-one/resource-policy.yaml
[up-rvps-sample]: https://github.com/confidential-containers/trustee-operator/blob/v0.19.0/config/samples/all-in-one/rvps-reference-values.yaml
[up-trusteeconfig-crd]: https://github.com/confidential-containers/trustee-operator/blob/v0.19.0/config/crd/bases/confidentialcontainers.org_trusteeconfigs.yaml
