# Repeatable actions for the organizational workflows

This runbook expands the numbered steps in the
[Confidential Containers operating playbook](../getting-started-and-operations.md). It describes the
mechanical sequence at each step: what to collect, render, review, change, verify, and retain. It is
not a substitute for a human approval or the live Red Hat procedure.

The fixed baseline is OpenShift sandboxed containers (OSC) 1.12, Red Hat build of Trustee 1.1,
local `kata-cc` on AMD SEV-SNP bare metal, and a separate trusted OpenShift cluster for Trustee.
Repository helpers demonstrate actions on the test rig. Production execution must use separate
cluster contexts, the customer's approved GitOps, PKI, secret, backup, and change systems, and the
version-matched Red Hat procedure.

## Workflow one — establish a net-new service

| Step | Mechanical actions | Existing implementation or reference | Produced or verified |
|---:|---|---|---|
| <a id="w1-1"></a>1. Approve intent | Record the use case, protected-data flow, administrator threat, exclusions, SLO, RTO, and RPO; route the record to the service and data owners for signature. | Human action; [HA01](../getting-started-and-operations.md#ha01) | Signed HA01 and decision ID |
| <a id="w1-2"></a>2. Freeze the BOM | Query both clusters for exact platform, node, RHCOS, Operator, and image versions; resolve mutable image references to digests; date the OSC 1.12 compatibility and release-note evidence; review the result. | OpenShift inventory commands plus the [OSC 1.12 release notes](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/release_notes/index) | Reviewed [HA02](../getting-started-and-operations.md#ha02) with exact versions, digests, and capture date |
| <a id="w1-3"></a>3. Approve design and owners | Draw the workload/Trustee separation and network/trust flows; assign a primary, backup, approver, and escalation route to every activity; test the contact paths. | Human action; [HA03](../getting-started-and-operations.md#ha03) and [HA04](../getting-started-and-operations.md#ha04) | Signed architecture and responsibility records |
| <a id="w1-4"></a>4. Prove readiness | Validate repository manifests; check SNP readiness on every eligible worker; inventory cluster, pool, catalog, and mirror state; run DNS, NTP, TLS, route, registry, capacity, and guest-to-Trustee/registry probes; assign every failure. | Repository lint, SNP host check, baseline validator, and [installation plan](install-execution-plan.md); customer probes are still required | [HA05](../getting-started-and-operations.md#ha05) with a result and owner for every prerequisite |
| <a id="w1-5"></a>5. Establish Trustee | Confirm the trusted-cluster context; prepare the Restricted Trustee configuration, TLS and administrator trust; collect the normal VCEK bundle once per eligible AMD host; generate RVPS values from the exact release, host, and initdata; render and review AS/KBS policies and resource references; apply through the approved path; capture generated state; run an allow test, a denial test, and restore the baseline. | [Red Hat Trustee 1.1 procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/configure-trustee-overview_metal-trustee-disconnected); repository VCEK, RVPS, Trustee, and policy helpers are rig references | MA01, relevant HA06/HA09 references, healthy rollout, policy/reference hashes, and paired allow/deny evidence |
| <a id="w1-6"></a>6. Enable the runtime | Confirm the workload-cluster context; install NFD and OSC; apply the required feature configuration and `KataConfig`; drain/reboot nodes in the approved sequence; verify intended labels and pool health; capture the Operator-generated `RuntimeClass/kata-cc`. | [Red Hat OSC 1.12 configuration](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc); repository install helper is a rig reference | MA03 platform baseline and healthy Operators, nodes, pools, labels, `KataConfig`, and runtime class |
| <a id="w1-7"></a>7. Build the reference workload | Build and scan the image; create SBOM/provenance; publish by digest; sign and, when required, encrypt; finalize the digest-pinned workload manifest; generate and review a complete Kata Agent policy; create initdata; regenerate matching RVPS/policy inputs; render and deploy outside production. | Repository build, signature, encryption, initdata, policy, and workload renderers are implementation references; see [initdata](#initdata), [Kata policy](#kata-agent-policy), and [Trustee policies](#trustee-policies) below | Matched MA02/MA03 revisions with immutable OCI identity, policy/initdata hashes, and non-production deployment evidence |
| <a id="w1-8"></a>8. Prove release and denial | Run the allowed release and every denial relevant to the contract; collect Pod identity, node, events, guest/application result, Trustee decision, registry result, and correlated timestamps; restore any temporary test policy; distinguish a policy denial from unrelated infrastructure failure. | Repository paired rung tests, negative tests, and reproducibility loop are rig references | [HA07](../getting-started-and-operations.md#ha07) showing allowed release, fail-closed behavior, and restored baseline |
| <a id="w1-9"></a>9. Activate operations | Install dashboards and alerts; schedule safe synthetic allow/deny transactions; configure support collection and redaction; schedule backups; restore into an isolated replacement; rehearse triage; measure RTO/RPO. | Red Hat observability and troubleshooting procedures plus local [debug surface](debug-surface.md) and [failure modes](failure-modes.md); production monitoring and recovery automation are customer-owned gaps | [HA08](../getting-started-and-operations.md#ha08), [HA09](../getting-started-and-operations.md#ha09), routed alerts, forced-failure triage, and restore evidence |

## Workflow two — onboard or change a workload

| Step | Mechanical actions | Existing implementation or reference | Produced or verified |
|---:|---|---|---|
| <a id="w2-1"></a>1. Intake | Open the release/change record; name the data, namespace, immutable image subject, resource URI, runtime/storage/network needs, expected release conditions, changed artifacts, owners, and requested date. | Human action tied to current HA02, HA06, and MA01–MA03 revisions | Reviewable intake record with complete affected-artifact list |
| <a id="w2-2"></a>2. Build | Build and scan; create SBOM/provenance; publish and record the OCI digest; sign and optionally encrypt; finalize the manifest; generate/review the Kata Agent policy; create exact initdata; bind every item to the same image identity. | Repository image build/verification and workload renderers cover part of this sequence; scanner, SBOM, provenance, and production policy generator are customer pipeline responsibilities | Proposed MA02 with reproducible image, signature/encryption evidence, complete policy, and exact initdata |
| <a id="w2-3"></a>3. Authorize | Bind the approved OCI identity, initdata/guest/reference state, resource URI, policy revisions, and review/expiry date; map each condition to an enforceable control and denial case; obtain data and security signatures. | Human action; [HA06](../getting-started-and-operations.md#ha06) is a suggested organizational form, not a standard schema | Signed HA06 containing identifiers and conditions, not protected values |
| <a id="w2-4"></a>4. Configure trust | Copy the current MA01 source to a proposed revision; change the matched AS policy, KBS resource policy, RVPS values, verification keys, and resource references; preserve the prior revision; render, validate, diff, and obtain second-person review; apply outside production; wait for reconciliation; prove allowed and denied retrieval; roll back the test change. | [Trustee policies](#trustee-policies); local measurement-policy and RVPS renderers are narrow rig references | Reviewed MA01 revision, hashes/diff/approval, live reconciliation evidence, and rollback pointer |
| <a id="w2-5"></a>5. Deploy | Create the dedicated Namespace, ServiceAccount, and RBAC; set placement, network, storage, and PodVM-sized resource controls; insert the digest-pinned image and encoded initdata; set `runtimeClassName: kata-cc`; render and diff; deploy outside production; capture the live Pod identity and exact applied annotation. | Repository workload render-only mode and rung deployers are rig references; production uses customer GitOps | Applied MA03 revision with Pod UID, node, runtime, image ID, and initdata digest matching approval |
| <a id="w2-6"></a>6. Prove | Run the positive case first, then the applicable wrong-image, wrong-initdata/reference, forbidden-resource, missing-key, collateral/TLS, and application denial cases; preserve inconclusive evidence; correlate both clusters and the guest; restore temporary policy. | Repository paired rung and negative tests cover selected cases | HA07 demonstrating capability to succeed and fail-closed behavior for the changed conditions |
| <a id="w2-7"></a>7. Promote | Promote the exact tested OCI digest and MA01/MA02/MA03 Git revisions without rebuilding; preview the production diff; approve the window and matched rollback set; apply through customer GitOps. | No repository production promotion controller | Production change record whose revisions equal the accepted test revisions |
| <a id="w2-8"></a>8. Observe | Run release-specific queries and the safe synthetic transaction for the full observation window; correlate startup, attestation, resource release, registry, capacity/latency, and application signals; route unexplained denial to its owner. | Red Hat observability plus local diagnostic references; dashboards, alerts, synthetics, and closeout are customer automation | Observation record, release closure, or assigned unresolved finding |

## Workflow three — upgrade or security-sensitive change

| Step | Mechanical actions | Existing implementation or reference | Produced or verified |
|---:|---|---|---|
| <a id="w3-1"></a>1. Scope | Snapshot the current BOM and desired state; resolve the intended target versions/digests; date the applicable OSC 1.12 and Trustee 1.1 update references; name environments, dependencies, window, stop conditions, and rollback triggers. | Same inventory action as [W1.2](#w1-2), followed by human review | HA10 scope and before/after HA02 |
| <a id="w3-2"></a>2. Assess impact | Diff current and target state; evaluate guest measurements, initdata, Kata policy, AS/KBS policy, RVPS, signatures/keys, TLS/admin trust, VCEK/TCB, node reboots, capacity, registry, and applications; assign an owner, regeneration action, test, and rollback dependency to every affected input. | Product release/update notes plus desired-state diff; human analysis remains required | Owned impact matrix with no unassigned trust input |
| <a id="w3-3"></a>3. Protect | Run the approved backup of desired state, policies, RVPS/reference data, protected-resource backends, VCEK cache, credentials, certificates/keys, and cluster configuration; restore into an isolated replacement; compare revisions and run one allow and one deny case. | Customer backup/key systems; the repository has no end-to-end backup/restore action | Backup-set ID and [HA09](../getting-started-and-operations.md#ha09) proving recovery within RTO/RPO |
| <a id="w3-4"></a>4. Rehearse | Mirror the exact target inputs into the lab; execute the proposed production sequence; record every stage; run platform, allow/deny, application, monitoring, restore, and rollback gates; assign findings and repeat until clean. | Product update procedures plus repository validators and test rungs where applicable | Timestamped lab implementation record and resolved findings |
| <a id="w3-5"></a>5. Re-establish trust | Use the impact matrix to regenerate only invalidated matched artifacts: initdata/Kata policy/RVPS/AS/KBS state, images/SBOM/provenance/signatures, normal per-host VCEK material, or PKI/key references; review new versus old; retain the complete old matched set. | [Regeneration triggers](#regeneration-triggers) and artifact-specific actions below | Versioned replacement MA01/MA02 artifacts plus a usable rollback set |
| <a id="w3-6"></a>6. Prove all gates | Re-run platform health, allowed release, relevant denials, application checks, monitoring, isolated restore, and matched rollback; verify that no policy was weakened merely to make the test pass. | Repository lint/validators/tests cover selected rig gates; production monitoring, restore, and rollback proof remain customer actions | HA07, HA08, HA09, and rollback evidence with all stop gates resolved |
| <a id="w3-7"></a>7. Authorize | Present scope, impact, support position, lab evidence, recovery access, capacity, sequence, communications, window, stop conditions, rollback authority, and observation period; record the go/no-go decision. | Human change authority | Formal decision with every technical prerequisite complete |
| <a id="w3-8"></a>8. Execute | Apply one approved stage at a time using the live Red Hat order and customer GitOps; record the command/change ID and health result; evaluate the checkpoint before continuing; stop and execute the matched rollback/recovery path at a defined no-go condition. | [OSC 1.12 update procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/update-osc-cc-overview_metal-cc) and [Trustee 1.1 update procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/update-trustee-overview_metal-trustee); repository install/uninstall targets are not production update/rollback | Timestamped implementation log and per-stage health/decision evidence |
| <a id="w3-9"></a>9. Accept and retire | Repeat HA07 and observation queries; reconcile live objects and digests with desired state; update HA02/MA01/HA08/HA09/HA10; approve acceptance; retire or retain old keys/resources/revisions according to the rollback and retention decision. | Human acceptance plus read-only reconciliation | Closed HA10 and explicit disposition for every superseded artifact |

<a id="regeneration-triggers"></a>
## Regeneration triggers

| Changed input | Mechanical action | Required retest |
|---|---|---|
| Initdata content, including embedded Kata policy | Rebuild the source, encode, decode/compare, hash, regenerate matching reference/policy inputs, and update MA02/MA03 | Matching initdata allowed; old or tampered initdata denied |
| Workload manifest affecting guest operations | Regenerate and review the complete Kata Agent policy; repeat initdata and reference-value actions when it is embedded | Required lifecycle allowed; forbidden guest action and `oc exec` denied |
| Application image or dependencies | Rebuild, rescan, regenerate SBOM/provenance, digest-pin, sign, and optionally encrypt | Signed image allowed; unsigned/tampered/wrong-key controls denied |
| AS/KBS policy, RVPS, or HA06 authorization | Create a new matched MA01 revision; render, diff, review, apply, and retain rollback | Approved request allowed; forbidden resource/identity/reference denied |
| AMD hardware, firmware, or TCB | Run the same normal VCEK collection once for each affected host and regenerate affected reference values | Attestation/release allowed on affected nodes; stale or wrong collateral denied |
| TLS, token, signing, or encryption trust | Rotate through the owning PKI/key process and update public references without storing private material in Git | New trust allowed; revoked, old, or wrong trust denied |

<a id="initdata"></a>
## Initdata

Initdata is integrity-protected launch configuration, not a secret container. Do not put passwords,
private keys, bearer tokens, image-decryption keys, or protected values in it.

The repeatable action is:

1. Start from the version-controlled `gitops/base/workloads/initdata.example.toml` structure.
2. Fill the exact Trustee URL and CA, registry configuration and CA, KBS resource URIs, and the
   complete reviewed Kata Agent `policy.rego`; reject unresolved placeholders.
3. Review and hash the exact source bytes. Whitespace and comments are part of the measured input.
4. Deterministically gzip/Base64 encode the source. The repository reference is
   `scripts/encode-initdata.sh`.
5. Decode the produced value, compare it byte-for-byte with the approved source, and record both
   source and encoded hashes.
6. Put the encoded value in
   `io.katacontainers.config.hypervisor.cc_init_data` through the environment's MA03 overlay.
7. Regenerate and review matching RVPS/reference inputs from the exact final source. The rig
   reference is `scripts/gen-rvps-veritas.sh`.
8. Render and deploy outside production; capture the live annotation; decode and compare it with
   the approved source; run one matching allow and one mismatched-initdata denial.

Changing the TOML, embedded policy, CA, endpoint, registry mapping, or final workload restarts the
entire sequence. The local template currently omits `policy.rego`; it demonstrates initdata plumbing
but is not a production-complete MA02 source.

<a id="kata-agent-policy"></a>
## Kata Agent policy

The Kata Agent policy controls host-to-guest API requests. It is distinct from Trustee attestation
and resource policies, RVPS reference values, image signature policy, and cluster admission policy.

The repeatable action is:

1. Finalize the complete digest-pinned workload manifest first.
2. Generate a complete policy from that manifest using either the OSC 1.12 product baseline or a
   `genpolicy` toolchain proven to match the exact OSC 1.12 guest assets in HA02. Record the tool
   identity, settings/rules, input digest, and output digest.
3. Review the full Rego for container lifecycle, commands, files, mounts, identities, network, and
   policy-replacement behavior. A custom policy replaces the default; it is not a partial overlay.
4. Ensure `ExecProcessRequest` is denied in production so `oc exec` cannot enter the confidential
   workload; keep only the operations the workload actually needs.
5. Embed the reviewed policy in initdata and repeat the complete initdata/RVPS/policy action.
6. Prove required startup and application behavior, and prove denial of `oc exec`, an unlisted or
   modified guest operation, and policy replacement.

This repository has no production generator pinned to OSC 1.12, and its current initdata template
omits the policy. Upstream `genpolicy` describes the mechanism, but a rolling upstream build must not
be assumed to match the Red Hat 1.12 guest.

<a id="trustee-policies"></a>
## Trustee policies and reference data

| Artifact | Mechanical action | Verification |
|---|---|---|
| AS attestation policy | Copy the current approved source; change only the claims/reference dependencies required by HA06; render a proposal; validate and hash it; review the full diff; retain the old revision; apply through the Trustee path. | Known-good evidence accepted; wrong measurement/reference denied; live revision equals approved source |
| KBS resource policy | Map exact resource paths and accepted claims from HA06 with default-deny behavior; render, hash, diff, review, and apply it with the matched AS/RVPS change. | Approved path/identity accepted; forbidden resource or identity denied |
| RVPS values | Generate from the exact supported release, guest/initdata input, and affected host; inspect non-empty output; merge it into the proposed MA01 revision rather than applying an unreviewed temporary file. | Live values correlate to HA02/MA02; correct reference accepted; stale/wrong reference denied |
| VCEK material | Run the normal collection once per eligible AMD host; in a disconnected environment carry only the required request/response through the approved transfer path; inventory host, certificate digest/issuer/validity, source, and collection time. | Every intended host succeeds; missing/wrong cache denies; restored correct cache succeeds |
| Verification keys and protected-resource references | Put public verification material and resource metadata in the desired source; load protected values through the approved KMS/secret backend; rotate and back up using the owning process. | Only an approved attested/authorized request resolves the resource; Git/evidence contains no private key or protected value |

The durable change is the reviewed MA01/GitOps revision, not an interactive `oc edit`. The local
measurement-policy renderer proves one narrow initdata-hash pattern; permissive base policies and
empty RVPS are evaluation scaffolding, not a production starting point.

## Production automation gaps to assign

| Required outcome | Current repository coverage |
|---|---|
| Customer-specific HA05 network, PKI, registry, capacity, and guest-path evidence pack | Individual platform checks exist; no consolidated production probe/evidence job |
| OSC-1.12-matched Kata Agent policy generation | No pinned production generator |
| Image scan, SBOM, and standardized provenance bound to one OCI digest | Build/sign/encrypt checks exist; supply-chain evidence pipeline is absent |
| Restricted, separate-cluster Trustee deployment with reviewed revisions | Test rig uses a direct, permissive `KbsConfig` path and can colocate components |
| Production GitOps promotion of a matched MA01/MA02/MA03 set | No promotion controller |
| Scheduled monitoring, alerts, synthetics, and cross-cluster evidence capture | Diagnostic and test helpers exist; operational automation is absent |
| Trustee backup, isolated restore, measured RTO/RPO, and matched rollback | No end-to-end recovery automation |
| OSC/Trustee upgrade orchestration and rollback | Product procedures exist; repository install/uninstall targets are not upgrade/rollback tools |

## Primary references

- [Red Hat OSC 1.12 bare-metal configuration](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc)
- [Red Hat Trustee 1.1 disconnected configuration](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/configure-trustee-overview_metal-trustee-disconnected)
- [Red Hat OSC 1.12 update procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/update-osc-cc-overview_metal-cc)
- [Red Hat Trustee 1.1 update procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/update-trustee-overview_metal-trustee)
- [Upstream initdata specification](https://github.com/confidential-containers/trustee/blob/v0.19.0/kbs/docs/initdata.md)
- [Upstream Kata Agent policy and `genpolicy`](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-the-kata-agent-policy.md)
- [Repository implementation map](../research/workflow-automation-map.md)
- [Repository Make targets](../../Makefile)
