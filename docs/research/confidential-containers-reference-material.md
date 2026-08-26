# Confidential Containers on OpenShift: primary-source research and beginner-first documentation blueprint

Research date: **2026-08-26**

Purpose: give the authors of a customer-facing operations guide a primary-source evidence base, a
plain-language mental model, and a proposed structure that does not assume prior knowledge of
Confidential Containers (CoCo), Kata Containers, attestation, or Trustee.

This is research, not a replacement for the versioned Red Hat product documentation. The live Red Hat
compatibility matrix and release notes are the authority for supported combinations.

> **Execution baseline is locked to OSC 1.12 and Red Hat build of Trustee 1.1.** References to 1.13
> exist only to document drift and future migration considerations. Do not use 1.13 commands, CR
> fields, images, or procedures in the 1.12 customer implementation without a separately approved
> migration and validation effort.

## How to read the labels

- **Red Hat 1.12** means documented behavior in OpenShift Sandboxed Containers (OSC) 1.12, the
  version implemented by this repository together with Red Hat build of Trustee 1.1.
- **Red Hat current** means the newer OSC 1.13 / Red Hat build of Trustee 1.2 documentation that was
  available on the research date. Do not copy its commands or CR fields into a 1.12 procedure without
  validating them.
- **Upstream concept** explains how the CNCF Confidential Containers, Kata Containers, or Trustee
  projects are designed. It is not by itself a Red Hat support statement.
- **Operating recommendation** is a proposed customer responsibility or control inferred from the
  architecture. It is not presented as a Red Hat-prescribed RACI or support policy.

## Executive findings

1. The shortest useful explanation is: **OpenShift still schedules a pod, but Kata runs that pod in a
   small confidential VM. Trustee checks proof about that VM before it releases a key or secret.** The
   `kata-cc` runtime is the Red Hat bare-metal path; `kata-remote` is the peer-pods path where a cloud or
   remote hypervisor creates the PodVM. ([Red Hat 1.12 terms][rh12-trustee],
   [upstream design overview][coco-design])
2. CoCo is not one component. It is a chain spanning hardware/firmware, OpenShift and CRI-O, the OSC
   Operator, Kata host and guest components, Trustee, vendor endorsements, workload images, policies,
   keys, storage, networking, and an application. The documentation must show ownership across the
   whole chain rather than treating “install the Operator” as the finish line.
3. The security decision has two distinct stages: the Attestation Service decides what the evidence
   says about the TEE/TCB, then the KBS resource policy decides whether that attested identity may
   receive a particular resource. A third policy, enforced by the Kata Agent inside the TEE, restricts
   commands from the untrusted host. ([Trustee architecture][coco-attestation-architecture],
   [policy overview][coco-policies])
4. Hardware attestation normally measures the guest firmware, kernel, command line, and root
   filesystem—not the workload container itself. Image signing is therefore a second-stage identity
   control. Encryption keeps image content confidential; signing supplies authenticity and integrity.
   Production designs generally need both, plus restrictive policies. ([upstream trust model][coco-trust],
   [signed images][coco-signed], [encrypted images][coco-encrypted])
5. Trustee belongs in a **separate OpenShift cluster in a trusted environment** in the Red Hat product
   architecture. Its operator lifecycle, policies, TLS identity, admin credentials, reference values,
   vendor endorsement cache, key/resource backend, backups, and recovery all need named owners.
   ([Red Hat Trustee guide][rh12-trustee])
6. The local implementation baseline and the current Red Hat documentation have already diverged.
   This repository says OSC 1.12 / Trustee 1.1 and records older OpenShift z-stream floors; the live
   product pages now publish revised z-stream minima, and OSC 1.13 / Trustee 1.2 are available. Every
   runbook should declare a tested bill of materials and link—not transcribe—the live matrix.
   ([1.12 compatibility][rh12-compat], [1.13 compatibility][rh13-compat])
7. Red Hat documents Operator installation, configuration, update, OSC metrics, logs, `must-gather`,
   and uninstall. It does **not** provide an end-to-end Trustee backup/disaster-recovery procedure in
   the reviewed 1.12 guides. A production guide must explicitly fill that operational design gap and
   test recovery; upstream also warns that KBS data is not persistent when no persistent storage
   backend is configured. ([OSC operations][rh12-cc], [upstream KBS configuration][trustee-kbs-config])

## Beginner mental model

| Term | Plain meaning | What it accomplishes | What it does **not** accomplish |
|---|---|---|---|
| Confidential computing | Hardware creates an isolated execution area whose contents the host/hypervisor is not supposed to read or change. | Protects selected data **while it is being used**. | Does not automatically protect data before it enters or after it leaves the TEE. |
| TEE / confidential VM | For this solution, the protected area is usually the small VM that backs one pod. | Makes the PodVM, not the OpenShift worker, the confidentiality boundary. | Does not make the application code correct or safe. |
| Kata Containers | A Kubernetes-compatible runtime that represents a pod as a VM and runs `kata-agent` inside it. | Lets a workload opt into VM isolation with a `RuntimeClass`. | Ordinary Kata isolation alone does not prove that the VM is the expected confidential VM. |
| Attestation | Cryptographic evidence about the TEE and its measured boot state is checked against endorsements, policy, and known-good values. | Lets a remote party decide whether to trust this specific launch. | Is not a vulnerability scan, penetration test, or guarantee of application behavior. |
| Trustee | The trusted-side KBS, Attestation Service, RVPS, policies, and resource backends. | Verifies evidence and conditionally releases resources. | Must not be treated as an unimportant in-cluster helper; compromise of Trustee compromises release decisions. |
| Reference value | A known-good measurement or TCB expectation used to appraise evidence. | Converts raw measurements into a meaningful allow/deny decision. | It does not update itself when guest assets, OpenShift, firmware, or policy change. |
| Initdata | Dynamic configuration delivered at VM launch and cryptographically bound to the evidence. | Protects **integrity** of KBS addresses, CA material, and Kata policy supplied at launch. | Upstream explicitly says initdata is visible to the untrusted host, so it does not protect confidentiality. |
| Signed image | An OCI image plus a verifiable publisher signature. | Authenticates the image and detects tampering when the in-guest policy verifies it. | Does not hide image contents. |
| Encrypted image | OCI layers encrypted with a key released only to an accepted TEE. | Keeps protected image content from being exposed outside the TEE. | Does not by itself authenticate the publisher or ensure the plaintext is safe. |
| Sealed secret | Upstream mechanism that stores a pointer or wrapped secret in Kubernetes and resolves it inside the TEE after attestation. | Keeps plaintext out of the ordinary Kubernetes secret path. | This upstream feature must not be claimed as supported on a particular OSC release without a Red Hat source and test. |

Sources: [Kata architecture][kata-architecture], [CoCo design][coco-design],
[CoCo trust model][coco-trust], [Trustee overview][coco-attestation], and
[initdata specification][trustee-initdata].

## Product support reality and deployment models

### Version discipline

- This repository's declared baseline is **OSC 1.12, Red Hat build of Trustee 1.1, and AMD SEV-SNP
  bare metal**, with a separate Trustee cluster and disconnected operation.
- OSC is documented as a **Rolling Stream Operator**: the latest version is the supported version.
  Current examples are not perfectly uniform about z-stream tags, so commands, CSVs, and must-gather
  images must match what is actually installed. Record the installed CSV and image digest instead of
  copying a stale `1.13.0` or `1.13.1` example. ([OpenShift Operator life cycles][operator-lifecycle])
- Red Hat's OSC 1.12 release notes identify Trustee 1.1.0 as the recommended version and document the
  `TrusteeConfig` CR, Restricted/Permissive profiles, and encrypted block volumes.
  ([1.12 release notes][rh12-release])
- Current Red Hat documentation also includes **OSC 1.13 and Trustee 1.2**. The current 1.13 matrix
  lists bare metal with Intel TDX or AMD SEV-SNP as GA at published z-stream floors, Azure and ARO
  peer-pods paths, and IBM Z variants. It does not mark Confidential Containers on AWS or Google
  Cloud as supported in that matrix. ([1.13 product landing][rh13-landing],
  [1.13 compatibility][rh13-compat])
- Current examples identify OSC Operator 1.13.1 and Red Hat build of Trustee Operator 1.2.0, but some
  pages/examples still contain other z-stream tags. Discover the installed CSV and use the matching
  product image/must-gather tag rather than treating any example tag as a universal constant.
- The live compatibility pages are updated after initial publication. On 2026-08-26 the 1.13 table
  listed OCP `4.19.38+`, `4.20.29+`, `4.21.24+`, and `4.22.5+` columns. Treat these as a dated
  observation, not a forever pin. The customer guide should say “check the live matrix immediately
  before install or upgrade.”
- As of the research date, Azure/ARO disconnected confidential containers, hosted-control-plane
  deployment, Azure confidential GPU, and AWS STS authentication were listed as Technology Preview
  in 1.13. Technology Preview features are not intended for production and are outside normal
  production support SLAs; preserve the GA/TP label next to every design option.
  ([1.13 Technology Previews][rh13-tp], [Technology Preview support scope][rh-tp-scope])
- Red Hat's production support scope covers supported installation, use, configuration, diagnosis,
  and qualifying defects; it does not make Red Hat the author of the customer's network design,
  security rules/policies, third-party integrations, or uncertified hardware decisions. The RACI must
  keep those activities with the customer. ([Red Hat support scope][rh-support-scope])
- Red Hat's FIPS statement is runtime-specific: it applies to the local `kata` runtime; the peer-pod
  `kata-remote` runtime is not fully supported/tested for FIPS compliance. Treat “OCP is in FIPS mode”
  and “this CoCo deployment has a documented FIPS posture” as separate validation questions.
  ([1.12 product discovery/FIPS caveat][rh12-compat])
- Do not infer product support from an upstream Helm runtime class or cloud example. Upstream charts
  and Red Hat's downstream OSC distribution have different prerequisites, CRI/runtime integration,
  packaging, and support boundaries. For example, the upstream Helm guide says bare-metal CRI-O is
  not tested there; Red Hat OpenShift uses its supported CRI-O integration.
  ([upstream cluster prerequisites][coco-cluster], [Red Hat 1.12 bare-metal guide][rh12-cc])

### Deployment choice

| Pattern | Where the PodVM runs | Why choose it | Principal customer responsibilities | Support caution |
|---|---|---|---|---|
| Bare-metal Kata (`kata-cc`) | Locally on a TEE-capable RHCOS worker. | Direct ownership of hardware, predictable placement, and no cloud PodVM API dependency. | Buy/certify hardware, enable UEFI/TEE firmware, maintain BIOS and firmware, label/discover nodes, capacity-plan per-pod VMs, and keep vendor endorsements current. | Use the live Red Hat bare-metal compatibility table; upstream host recipes are diagnostic background, not an OpenShift install procedure. |
| Peer pods (`kata-remote`) | A Cloud API Adaptor or remote hypervisor creates a separate PodVM; the OpenShift worker can be virtualized. | Avoids nested virtualization and integrates with supported confidential-VM offerings. | Cloud IAM/credentials, PodVM image, quotas, subnet/route/firewall, instance cleanup/cost control, and guest-to-Trustee/registry connectivity. | Support is platform-specific. In current Red Hat CoCo docs Azure/ARO and IBM Z have product guides; an upstream AWS/GCP example is not a Red Hat support statement. |
| Disconnected bare metal | Local PodVM, but cluster/Trustee cannot rely on public registries or hardware-vendor endpoints. | Meets air-gap policy. | Mirror every release/operator/workload/guest artifact, distribute trust bundles, cache all hardware endorsements, prove public egress is actually blocked, and refresh caches after firmware/TCB changes. | Follow the matching Red Hat disconnected Trustee guide and OCP mirroring docs; a connected happy path does not prove disconnected operation. |

Sources: [Red Hat terms and topology][rh12-trustee], [Red Hat disconnected Trustee guide][rh12-trustee-disconnected],
[upstream peer-pods overview][coco-design], and [Cloud API Adaptor][caa].

### Common prerequisite gate

Do not begin the Operator installation until every item has an owner and evidence:

| Gate | Acceptance evidence | What passing the gate accomplishes |
|---|---|---|
| Supported bill of materials | Recorded OSC, Trustee, OCP z-stream, architecture, TEE, deployment pattern, feature support level, and registry image digests, checked against the live matrix. | Prevents assembling a combination that Red Hat has not documented as supported. |
| Trusted-service location | Separate supported OCP cluster/environment for Trustee; identified administrators and network endpoints. | Removes the release authority from the untrusted workload cluster. |
| Hardware readiness | UEFI; required AMD SEV-SNP or Intel TDX settings; correct firmware; kernel reports the TEE; a standalone readiness test passes on every eligible node. | Proves the platform can create a confidential VM before OpenShift/Kata complexity is added. |
| Cluster and access | RHCOS workers, supported OCP z-stream, cluster-admin for install, `oc`, catalog access or mirrored catalog. | Establishes the supported control plane and operator lifecycle. |
| Network path | Guest—not only pod/host—can resolve and reach Trustee and registries; required TLS roots are available inside the guest; peer-pod/cloud routes and proxies are defined. | Makes attestation, secret delivery, and in-guest image pull possible. |
| Trust material | TLS server identity, admin authentication, hardware endorsements, RVPS values, attestation policy, KBS resource policy, image verification keys, and protected resources are inventoried. | Makes a cryptographic allow/deny decision possible instead of merely starting a confidential VM. |
| Recovery and rotation | Backup owner, restore procedure, certificate/key rotation procedure, firmware-event procedure, and negative tests are agreed. | Makes the platform operable after day one. |

Red Hat's bare-metal prerequisite page requires a compatible OCP release, Trustee in a trusted
environment, and UEFI; AMD's official material describes the SNP firmware/attestation chain and the
AMD KDS/VCEK model. ([Red Hat installation prerequisites][rh12-install],
[AMD SNP attestation][amd-snp-attestation], [AMD VCEK/KDS specification][amd-vcek])

## Architecture and component ownership

### What runs where

| Component | Plain responsibility | Location | Security stance | Suggested accountable owner |
|---|---|---|---|---|
| OpenShift control plane, scheduler, kubelet, CRI-O | Schedules the pod and calls the selected runtime. | Workload cluster | Outside the TEE; upstream threat model treats it as untrusted for confidentiality. It still controls availability. | OpenShift platform team |
| OSC Operator and `KataConfig` | Installs and reconciles the supported Kata runtime and runtime classes. | Workload cluster | Privileged platform management layer; not part of the confidential guest. | OpenShift platform team |
| Node Feature Discovery / TEE rule | Detects and labels nodes that can host the requested TEE. | Workload cluster | Scheduling signal; it is not itself attestation. | Infrastructure + platform teams |
| Kata shim/runtime and hypervisor/CAA | Translates CRI lifecycle calls into a local or remote PodVM and proxies Kata Agent requests. | Worker host, or worker plus cloud API | Outside the TEE; availability/control-plane component. | Platform team; cloud team for peer pods |
| PodVM firmware, kernel, command line, root filesystem | Boots the isolated guest and provides the measured base TCB. | Inside the TEE | Trusted only after its measurements and endorsements are appraised. | Red Hat supplies product assets; platform/security teams approve versions and reference values |
| Kata Agent policy | Restricts host-to-guest Kata operations such as process execution and mounts. | Enforced inside the TEE | Critical trust-boundary control; must be restrictive in production. | Workload security owner |
| Attestation Agent | Obtains fresh hardware evidence and participates in attestation. | Inside the PodVM | Trusted guest component included in the measured image. | Runtime supplier; operated through OSC |
| Confidential Data Hub (CDH) / image components | Requests resources, unwraps secrets, and handles signed/encrypted image operations. | Inside the PodVM | Trusted guest component; exposes a local API to the workload. | Runtime supplier plus workload integrator |
| KBS | Front door for guest attestation/resource requests; applies resource policy and returns approved resources. | Separate trusted Trustee cluster | High-value relying party and release authority. | Security/platform trust-service team |
| Attestation Service | Verifies hardware evidence, evaluates TCB policy, and issues an attestation result token. | Trustee | High-value verifier. | Security/platform trust-service team |
| RVPS/reference-value store | Holds known-good measurements used in appraisal. | Trustee | Change-controlled security data. Stale data can deny good workloads or weaken appraisal. | Security owner with release engineering input |
| Vendor endorsement service/cache | Supplies the certificate chain used to authenticate the hardware's evidence (for SNP, ARK → ASK → VCEK). | Vendor service or trusted offline cache | Root-of-trust input; cache contents and refresh are operational dependencies. | Hardware/firmware owner + trust-service owner |
| Resource/KMS/HSM backend | Stores image keys, secrets, tokens, and other protected resources. | Trusted service, external KMS/HSM, or configured backend | The confidentiality source of truth; availability and backup matter. | Enterprise key/secrets team |
| Registry and build/sign pipeline | Builds, scans, signs/encrypts, publishes, and retains OCI images and verification metadata. | Supply-chain systems | Second-stage workload identity and content protection. | Application/supply-chain team |
| Workload manifest and initdata | Selects runtime class and binds KBS/CA/Kata-policy configuration to the guest launch. | GitOps/application repo; injected into PodVM | Initdata has integrity, not confidentiality. | Application team with security approval |

The upstream persona model separates infrastructure operator, orchestration operator, workload
provider, image provider, and data owner. The suggested owners above map those generic personas to a
typical enterprise; customers can combine roles, but should not leave an activity ownerless.
([upstream personas][coco-personas])

### Responsibility matrix for customer operations

This is an **operating recommendation**, not an official Red Hat RACI.

| Activity | Infrastructure / firmware | OpenShift platform | Trustee / security | Application / supply chain | Data / risk owner | Vendor / Red Hat |
|---|---:|---:|---:|---:|---:|---:|
| Approve threat model and data scope | C | C | C | C | **A** | I |
| Confirm supported product/platform combination | C | **A/R** | C | I | I | C |
| Enable TEE firmware and patch host | **A/R** | C | C | I | I | C |
| Install/upgrade OCP, OSC Operator, and `KataConfig` | C | **A/R** | I | I | I | C |
| Operate separate Trustee cluster and availability | I | C | **A/R** | I | I | C |
| Own TLS/admin keys, endorsement cache, policies, RVPS, resources | C | C | **A/R** | C | C | C |
| Build, scan, sign/encrypt, publish images | I | I | C | **A/R** | C | I |
| Define restrictive Kata policy/initdata and workload spec | I | C | C | **A/R** | C | C |
| Approve which measurement/image may receive which secret | I | C | R | R | **A** | I |
| Monitor, test denials, collect evidence, and respond | R | R | **A/R** | R | I | C |
| Back up/restore Trustee desired state and protected resources | I | C | **A/R** | I | I | C |
| Rotate certs, signing keys, encryption keys, and secrets | I | C | **A/R** | R | C | I |

Key: **A** accountable, **R** responsible, C consulted, I informed.

## The trust and attestation chain, step by step

| Step | Activity | Simple callout: what this accomplishes | Primary component owner |
|---:|---|---|---|
| 1 | OpenShift schedules a manifest that selects `kata-cc` or `kata-remote`. | Opts this pod into the confidential runtime. | Platform + application |
| 2 | Kata creates a local or remote PodVM and boots the product guest assets with initdata. | Establishes an isolated execution boundary and a particular launch state. | Platform |
| 3 | TEE hardware measures the guest base and binds a fresh public key/challenge plus platform-specific data to evidence. | Makes evidence specific to this launch and resistant to replay/substitution. | Hardware/runtime |
| 4 | Attestation Agent sends evidence to KBS using the KBS request-challenge-attestation-response protocol. | Proves possession of the TEE-bound key and supplies fresh evidence. | Guest runtime + Trustee |
| 5 | KBS delegates evidence validation to the Attestation Service. | Separates protocol/resource brokering from hardware-specific verification. | Trustee/security |
| 6 | The verifier checks the vendor endorsement chain and extracts TCB claims. For SNP, AMD documents an ARK → ASK → VCEK chain, with the VCEK signing the report. | Establishes that evidence originated from authentic hardware/firmware at a reported TCB. | Trustee + hardware owner |
| 7 | Attestation policy compares claims with RVPS reference values and emits a generic attestation result token. | Turns raw measurements into a normalized trust result. | Trustee/security |
| 8 | KBS verifies/trusts the AS token and evaluates the resource policy for the requested resource URI. | Decides whether **this attested workload** may receive **this resource**. | Trustee/security + data owner |
| 9 | KBS/resource plugin obtains the resource and encrypts it to the TEE-bound public key; CDH receives it inside the guest. | Keeps plaintext from the untrusted host/control plane during delivery. | Trustee + guest runtime |
| 10 | CDH gives the key/secret to the workload or uses it to verify/decrypt an image or volume. | Enables the protected operation only after the decision succeeds. | Application/runtime |

Sources: [KBS protocol][trustee-kbs-protocol], [Trustee architecture][coco-attestation-architecture],
[attestation-token trust chain][trustee-token], and [AMD attestation example][amd-snp-attestation].

### Five trust chains the guide must name separately

1. **Hardware endorsement:** vendor roots authenticate the per-platform evidence-signing key.
2. **Measured guest:** firmware/kernel/command line/root filesystem and bound initdata identify the
   guest launch.
3. **Attestation result:** AS signing material lets KBS authenticate the token; upstream documentation
   says insecure header-key modes are suitable only for local testing.
4. **Workload supply chain:** an approved public key/policy authenticates the OCI image because the
   hardware measurement usually does not cover it.
5. **Trustee server/admin identity:** the guest must authenticate KBS through a trusted TLS identity,
   while only authorized administrators may change policy, reference values, or resources.

## Installation and configuration: proposed golden path

Each phase should be its own customer-facing page with **Goal**, **Owner**, **Inputs**, **Change**,
**What this accomplishes**, **Verification**, **Failure/rollback**, **Support/version**, and **Source**.

| Phase | Required activity | What it accomplishes | Minimum verification before proceeding |
|---:|---|---|---|
| 0 | Write threat model, data flow, trust boundaries, recovery objectives, and feature/support requirements. | Defines what is being protected, from whom, and what failure means. | Data/risk owner signs off; unsupported features are explicitly excluded or accepted. |
| 1 | Freeze tested bill of materials and deployment topology. | Prevents upstream/downstream and 1.12/1.13 configuration mixing. | Live Red Hat matrix checked and dated; image digests recorded. |
| 2 | Prepare hardware/cloud and network prerequisites. | Makes it possible to create and reach the confidential PodVM. | TEE readiness passes on every eligible node or supported cloud instance; guest route/DNS/TLS plan exists. |
| 3 | Install a separate trusted OpenShift environment for Trustee and protect administrative access. | Creates a trusted release authority outside the workload cluster. | OCP healthy; backup, RBAC, NetworkPolicy/firewall, time, DNS, and certificate lifecycle defined. |
| 4 | Install Red Hat build of Trustee Operator and a `TrusteeConfig`. Use **Restricted** for production. | Reconciles supported KBS/AS/RVPS resources and avoids permissive production defaults. | CSV succeeded; Trustee/KBS pods ready; service reachable over the intended TLS route; operator logs clean. |
| 5 | Provision TLS/admin trust, hardware endorsements or offline cache, RVPS values, attestation policy, resource policy, image verification keys, and test resources. | Gives attestation a real trust basis and an explicit fail-closed release rule. | Known-good evidence produces an affirming result and a known-bad reference/policy test is denied. |
| 6 | Install OSC Operator on the workload cluster and enable confidential containers. | Installs the supported OpenShift/Kata integration. | Operator CSV succeeded; confidential feature gate reconciled. |
| 7 | Install/configure TEE discovery and create `KataConfig`. | Labels eligible nodes and installs the confidential runtime class. | Eligible nodes are labeled; ineligible nodes are not; `KataConfig` ready; `kata-cc` or supported `kata-remote` RuntimeClass exists. |
| 8 | Create initdata containing guest configuration and a restrictive Kata Agent policy; bind it to the workload. | Authenticates launch-time configuration and blocks dangerous host-to-guest operations. | Initdata hash matches policy/reference expectations; `ExecProcessRequest` is disabled at minimum per Red Hat production guidance. |
| 9 | Build/scan, digest-pin, sign and where required encrypt the workload image; publish signature/key/policy resources. | Extends trust from the measured guest to the actual workload and keeps proprietary image content confidential. | Correct signed image runs; unsigned/tampered image is denied; wrong/missing decryption key prevents plaintext use. |
| 10 | Deploy workload with the correct runtime class, resource requests, initdata annotation, storage, and `imagePullPolicy`. | Launches the intended pod in the confidential boundary. | Pod is a confidential PodVM, attestation succeeds, only intended resource is released, application behavior passes. |
| 11 | Execute and retain negative tests. | Demonstrates that controls fail closed rather than merely proving one happy path. | At least: untrusted runtime, bad reference value/initdata, forbidden resource, unsigned/tampered image, wrong endorsement/cache, and expired/untrusted TLS are denied. |
| 12 | Hand off day-2 runbooks, dashboards, alerts, rotations, backup/restore, upgrade, and support collection. | Turns a demo into an operable service. | Named on-call owners perform a restore drill and an upgrade rehearsal in a non-production environment. |

Red Hat's documented order is Trustee in the trusted environment, OSC Operator on the workload
cluster, TEE discovery/feature gate, `KataConfig`, initdata, attestation verification, then the workload.
([1.12 Trustee guide][rh12-trustee], [1.12 bare-metal configure/install guide][rh12-cc])

## Image, secret, policy, and storage controls

| Control | Protects against | Customer activities | Source/support boundary |
|---|---|---|---|
| Restrictive Kata Agent policy | A malicious/compromised cluster administrator using allowed Kata APIs to inspect or modify the guest. | Generate policy for exact workload, include through measured initdata, disable `ExecProcessRequest` at minimum, test operational commands that must still work. | Red Hat 1.12 explicitly warns against permissive production policy and calls out `ExecProcessRequest`; upstream explains the policy trust boundary. ([Red Hat 1.12 configure][rh12-config], [Kata policy][kata-policy]) |
| Attestation policy + RVPS | Wrong TCB, firmware/guest measurement, or launch configuration being accepted. | Generate/reference known-good measurements; use Restricted profile; review policy; regenerate after relevant updates. | Red Hat 1.12 says to update the RVPS config map after OCP/OSC or workload configuration changes. ([1.12 Trustee update][rh12-trustee-upgrade]) |
| KBS resource policy | A genuine TEE receiving a resource it is not authorized to use. | Default deny; bind resource paths to affirming TCB/platform/workload/initdata claims; test forbidden resources. | Upstream default is not a production authorization design; its policy page says allow-all is generally insecure. ([Trustee policies][coco-policies]) |
| Signed image | Tampered or unapproved image. | Protect signing private key; publish public key; write default-deny image policy; sign digest; handle key rotation/revocation. | Red Hat Trustee guides document signature public-key secret and image security policy; upstream supplies broader cosign/simple-signing examples. ([Red Hat Trustee][rh12-trustee], [upstream signed images][coco-signed]) |
| Encrypted image | Registry, storage, or infrastructure viewing sensitive OCI layers. | Generate DEK; encrypt image; store/wrap key in approved KMS/KBS; authorize release; combine with signing. | Upstream feature. Verify the exact Red Hat release/registry/CRI-O path before claiming support. This repo records an unresolved local CRI-O pre-pull issue, which is implementation evidence, not a universal product limitation. ([encrypted images][coco-encrypted], [local tracked issue][crio-10084]) |
| Trustee resource / explicit CDH request | Kubernetes/control-plane access to an application secret. | Create resource URI, store resource in protected backend, write release policy, retrieve via CDH local API. | Red Hat documents KBS secret resources; upstream documents `kbs:///<repository>/<type>/<tag>` and the CDH API. ([Trustee resources][coco-resources], [get resource][coco-get-resource]) |
| Sealed secret | Plaintext in an ordinary Kubernetes Secret. | Choose vault pointer or envelope form, protect signing/unwrapping keys, bind to Trustee/KMS policy. | Upstream capability; current page was modified 2026-07-31. Confirm downstream support and version before including it in a Red Hat procedure. ([sealed secrets][coco-sealed]) |
| Private registry credentials | Registry authentication. | Keep scope narrow; rotate; ensure guest pull works; prefer encrypted image content. | Upstream currently warns that architecture limitations expose these credentials to the host, so registry auth must not be marketed as confidential. ([authenticated registries][coco-registry-auth]) |
| Encrypted raw block volume | Data at rest on persistent block storage. | Provide CSI raw block volume, store LUKS passphrase behind attestation, format/mount inside TEE, own backup/restore and key recovery. | Red Hat 1.12 release notes and bare-metal guide document encryption/decryption inside the TEE. ([1.12 release notes][rh12-release], [1.12 configuration example][rh12-config]) |
| Direct attestation/runtime-attestation API | A workload needing its own evidence/token. | Enable the smallest REST surface, bind runtime data/nonces, authorize callers, and understand shared-TCB identity. | Upstream says evidence access is disabled by default because a workload can become an “evidence factory”; runtime attestation also expands the guest API. Treat it as an opt-in attack-surface decision. ([get attestation][coco-get-attestation], [runtime attestation][coco-runtime-attestation]) |
| Protected ephemeral storage | Host reading/modifying guest scratch or image blocks. | Choose the exact supported storage mechanism, size it, plan space reclamation, and accept replay/ephemeral limitations. | Upstream confidential `emptyDir` has no replay protection; confidential image storage is experimental, ephemeral, and not a reusable cache. These are not Red Hat support claims. ([protected storage][coco-protected-storage], [confidential emptyDir][coco-emptydir], [confidential image storage][coco-image-storage]) |

Upstream image signature verification is configuration-dependent: if no image security policy is
installed, image pulls are not validated. “The image is signed” is therefore not evidence that the
guest verified it; retain the policy, public key, digest, and an unsigned/tampered denial test.
([signed images][coco-signed])

## Day-2 operating model

### Routine and event-driven activities

| Trigger / cadence | Activity | What it accomplishes | Evidence to retain | Primary owner |
|---|---|---|---|---|
| Continuous | Monitor OCP/OSC/Trustee Operator and KBS pod readiness, restarts, failed scheduling, PodVM launch latency/failures, attestation outcomes, resource denials, registry pulls, and backend health. | Detects failure at the layer where it starts. | Dashboard/alerts, selected logs, availability/error-rate SLOs. | Platform + Trustee teams |
| Daily | Run a synthetic known-good attestation/resource retrieval without printing the secret, plus a safe known-denied request. | Proves both availability and fail-closed behavior. | Success/denial timestamps and reason codes. | Trustee/security |
| Weekly/monthly | Review policy, reference value, signing-key, resource, TLS, admin-auth, Route/Service, and RuntimeClass drift against GitOps. | Detects unreviewed changes to the trust decision. | Diff/change ticket and reconciliation status. | Security + platform |
| Workload release | Build/scan/sign/encrypt new image digest; update approved key/policy/reference only after test; run positive and negative cases. | Onboards a new workload version without broadening trust accidentally. | SBOM/provenance, signature, digest, policy review, test results. | Supply-chain/application |
| OCP/OSC upgrade | Check live matrix and release notes; back up; stage update; update cluster (runtime comes through RHCOS) and Operator; regenerate/reapply RVPS values where required; retest. | Keeps the measured runtime and its expectations synchronized. | Before/after BOM, RVPS generation output, attest/deny tests, metrics. | Platform + Trustee/security |
| Trustee upgrade | Back up CRs/config maps/secrets/backends; update supported Operator; verify token trust, policies, resources, endorsements, and synthetic tests. | Changes the release authority without silently losing trust material. | CSV, config diff, restore point, positive/negative evidence. | Trustee/security |
| Firmware/microcode/BIOS event | Determine TCB/endorsement/measurement impact; update hardware; refresh VCEK/vendor material and reference values; quarantine nodes until tests pass. | Avoids both unexplained outages and accepting stale trust assumptions. | Firmware inventory, new cert chain/cache, new evidence, policy approval. | Infrastructure + Trustee/security |
| TLS/admin/signing key rotation | Introduce new trust, roll clients/policies, verify, retire old key; keep emergency recovery access controlled. | Maintains authentication without outage or indefinite trust of old keys. | Rotation record, validity dates, denial using retired key. | Security + supply chain as appropriate |
| Scale/capacity change | Validate hardware eligibility, per-pod VM CPU/memory/storage overhead, peer-pod quota/subnet/IP/instance limits, Trustee throughput and replicas. | Prevents confidential workloads from failing because they consume VM-shaped capacity. | Load test, quota/capacity report, scheduling test. | Platform/infrastructure |
| Incident | Freeze evidence, preserve logs/config/digests, disable affected resource paths or signing keys, quarantine nodes/images, rotate secrets, then re-attest. | Limits secret release while root cause is investigated. | Timeline, affected measurements/resources, revocations, recovery tests. | Security incident lead |
| Quarterly / before audit | Restore Trustee into an isolated replacement environment, re-establish TLS/routes/backends, then run known-good and known-bad workloads. | Proves recovery of the **decision system**, not merely Kubernetes objects. | RTO/RPO, restore log, attestation/denial results. | Trustee/security + platform |

### Monitoring and diagnostic sources

- Red Hat documents OSC/Kata Agent, guest OS, hypervisor, kata-monitor, and shim metrics in the
  OpenShift console/Prometheus. ([OSC Observe][rh12-observe])
- Red Hat documents enabling CRI-O debug logs, viewing runtime/hypervisor/agent logs, `KataConfig`
  status, and OSC-specific `must-gather`. Use the version-matched must-gather image rather than copying
  an old tag. ([OSC Troubleshoot][rh12-troubleshoot])
- Red Hat's 1.12 Trustee guide verifies pods and KBS/operator logs; the current 1.13 Trustee guide adds
  a Trustee-specific must-gather flow. Treat this as a versioned capability.
  ([1.12 Trustee][rh12-trustee], [1.13 Trustee][rh13-trustee])
- Upstream troubleshooting recommends narrowing the layer: ordinary pod, VM launch, guest boot,
  attestation, then image/resource retrieval. It also warns that enabling Kata debug options or a guest
  debug console can change the launch measurement. Do not debug a production TEE by bypassing its
  policy; reproduce safely in an isolated test environment. ([upstream troubleshooting][coco-troubleshoot])

### Backup and disaster recovery: explicit documentation gap

The reviewed Red Hat 1.12 CoCo/Trustee guides do not define a complete backup and DR procedure.
Do not claim “Trustee is backed up because OpenShift is backed up.” Define and test the following:

- GitOps copies of `TrusteeConfig`, customized generated `KbsConfig`, Services/Routes, NetworkPolicies,
  attestation and resource policies, RVPS inputs/outputs, and workload initdata sources.
- Secure backup of TLS private keys, AS token-signing keys and trust anchors, KBS admin credentials,
  offline endorsement caches, image verification keys, and KBS resources that are not externalized.
- Native backup/recovery for the external KMS/HSM/Vault and any persistent KBS backend; do not export
  HSM keys merely to satisfy a generic backup list.
- Registry retention for exact signed/encrypted image digests, signatures, guest/initrd artifacts, and
  the policy/reference bundle needed to appraise them.
- Reissuance plan for certificates and hardware-bound endorsements when restore occurs under a new
  DNS name, cluster, node, TCB, or firmware state.
- A test that proves an allowed workload can retrieve only its resource and disallowed workloads remain
  denied after recovery.

Upstream KBS documentation says that if `[storage_backend]` is omitted the default in-memory store is
not persistent across restarts. That warning applies to upstream configuration; inspect the actual
Red Hat Operator-generated configuration and CR-backed resources rather than assuming the same
default. ([upstream KBS storage configuration][trustee-kbs-config])

## Troubleshooting decision tree

1. **Can an ordinary non-Kata pod run on the target node?** If no, troubleshoot OCP/network/storage
   first. If yes, the base cluster is probably not the immediate fault.
2. **Are `KataConfig`, runtime class, node labels, OSC pods, and machine config pools ready?** If no,
   collect Operator status/logs and do not debug attestation yet.
3. **Does the PodVM start?** If no, inspect TEE firmware/kernel readiness, node eligibility,
   hypervisor/CAA logs, resource capacity, cloud quota/IAM, and PodVM image.
4. **Does the guest boot and Kata Agent answer?** If no, inspect guest console/runtime logs and exact
   initrd/kernel/command line. Remember debug changes may create a new measurement.
5. **Can guest components—not merely the application pod—resolve, reach, and authenticate KBS?** If
   no, correct guest DNS/route/proxy/TLS CA/initdata. Host or pod connectivity is not sufficient proof.
6. **Does evidence collection work?** If no, the guest image/TEE interface is wrong. If yes, continue.
7. **Does AS validate evidence?** Separate vendor endorsement/certificate failure, stale TCB/reference
   values, initdata mismatch, and attestation-policy denial. Do not weaken policy to make the error go
   away.
8. **Does KBS accept the token and resource request?** Check AS token-signing trust, resource URI,
   resource policy, admin-provisioned resource, and backend availability.
9. **For encrypted/signed images, can an unprotected image from the same registry start?** If not,
   fix registry/DNS/TLS/auth/pull routing first. Then validate key ID, signature transport, verification
   policy, key length/value, and in-guest pull behavior.
10. **Collect before changing:** pod describe/events, relevant CR/CRD status, OSC/Trustee Operator and
    KBS logs, CRI-O/Kata logs, machine config pool state, runtime class/node labels, live configuration
    with secrets redacted, BOM/digests, and version-matched Red Hat must-gather.

Sources: [Red Hat troubleshooting][rh12-troubleshoot], [upstream CoCo troubleshooting][coco-troubleshoot],
and [encrypted-image debugging cascade][coco-encrypted].

## Recommended beginner-first information architecture

The existing product and upstream docs are component- and procedure-oriented. A customer guide should
lead with outcomes, choices, ownership, and verification:

1. **Start here: what problem this solves** — a one-page story showing data at rest, in transit, and in
   use; one “what it does not protect” box.
2. **The five-minute architecture** — one bare-metal diagram, one peer-pods diagram, one attestation
   sequence; every box names its environment and owner.
3. **Who is responsible for what** — the customer-adapted RACI, trust administrators, separation of
   duties, Red Hat/hardware/cloud responsibilities, and escalation paths.
4. **Decide if this fits** — supported matrix link, threat-model worksheet, feature/support level,
   FIPS caveat, capacity/cost, connected/disconnected, bare metal/peer pods, recovery objectives.
5. **Preflight** — evidence-based gates for hardware, OCP version, trusted Trustee environment,
   network/DNS/time/TLS, registry/mirror, KMS/HSM, and access.
6. **Build the trust service** — install Trustee; configure Restricted profile, TLS/admin auth,
   endorsements, RVPS, policies, resources, HA, monitoring, backup, and rotation; include positive and
   negative checks.
7. **Enable the workload cluster** — OSC Operator, feature gate, NFD/rules, `KataConfig`, runtime
   classes, eligible node pools, and supported upgrades.
8. **Onboard one workload** — build/scan/digest/sign/encrypt; initdata and restrictive Kata policy;
   secret/resource and encrypted volume; workload YAML; acceptance and denial tests.
9. **Operate it** — daily/weekly/event runbooks, dashboards/alerts, capacity, certificate/key/reference
   lifecycle, upgrades, firmware changes, disconnected refresh, backup/restore, and DR exercise.
10. **Troubleshoot by layer** — the decision tree above, error-to-owner routing, safe debug guidance,
    must-gather and support case checklist.
11. **Security boundary and compliance appendix** — explicit trusted/untrusted elements, side-channel
    and denial-of-service limits, FIPS/support statements, and audit evidence map.
12. **Versioned reference** — exact tested BOM, CR field reference, glossary, direct official links,
    known issues, and last-validation date.

### Required page template

Every operational activity should answer the following in the same order:

1. **Goal** — one sentence.
2. **Owner / approver** — named team, not “the user.”
3. **Before you start** — version/support, permissions, inputs, outage/reboot impact.
4. **Action** — commands/manifests.
5. **What this accomplishes** — the security or operational outcome in plain language.
6. **Verify** — observable success **and** fail-closed/negative behavior.
7. **Rollback or recovery** — including node reboot, PodVM cleanup, or old trust overlap.
8. **Evidence to retain** — audit/change record without secret disclosure.
9. **When to repeat** — upgrade, image, firmware, certificate, or policy trigger.
10. **Source and version** — Red Hat product source first; upstream concept separately.

## Decisions and gaps to close before publishing a production guide

| Gap / decision | Why it matters | Required outcome |
|---|---|---|
| Product/version pin | Live docs and local repo pins differ. | One dated support matrix and tested BOM per guide release. |
| Threat model and protection claims | “Confidential” can be interpreted as protecting everything. | Approved in/out-of-scope statement covering host, control plane, side channels, DoS, app bugs, network, and storage. |
| Trustee HA/SLO | Secret release is a workload startup dependency. | Replica/topology, backend, capacity, alert, maintenance, and failure-mode design. |
| Trustee backup/DR | Official 1.12 docs lack an end-to-end procedure. | Artifact inventory, RPO/RTO, tested restore and post-restore denial test. |
| Token/TLS/admin key lifecycle | Insecure development defaults or expired certs can weaken trust or stop all starts. | Production trust-chain design and no-downtime rotation/revocation runbook. |
| Firmware/VCEK/reference lifecycle | Firmware and guest changes alter what evidence should be accepted. | Event matrix showing which artifact is regenerated, by whom, and node quarantine/re-enable steps. |
| Policy authorship and approval | Permissive/default policies do not express the customer's authorization intent. | Default-deny Kata, AS, KBS, and image policies with independent review. |
| Signed/encrypted image pipeline | Hardware measurement alone normally does not identify the container. | Supported registry/signature transport and key release pipeline with tamper/wrong-key tests. |
| Guest networking and proxy | Guest components have a different trust/network context from host and application. | Tested DNS, route, proxy, TLS CA, mirror, and egress matrix from inside a PodVM. |
| Disconnected refresh | Firmware/vendor endorsements and mirrored content age independently. | Scheduled content/endorsement refresh, provenance, expiry monitoring, and real egress-denial test. |
| Peer-pod cleanup/cost | Failed deletion can leave billable cloud VMs. | Orphan detector, quota/IP monitoring, cleanup verification, and cloud-owner escalation. |
| Observability/privacy | Logs and debug consoles can expose sensitive context or alter measurements. | Redaction/retention policy, safe synthetic transactions, versioned must-gather procedure. |

## Source catalog

### Red Hat product sources — use these for supported behavior

| Scope | Direct source | Version/date caveat |
|---|---|---|
| Product landing | [OSC 1.12 documentation set][rh12-landing] | Local repository baseline; live pages can receive updates. |
| Release content | [OSC 1.12 release notes][rh12-release] | Trustee 1.1.0 recommendation, `TrusteeConfig`, prebuilt initramfs, encrypted block volumes. |
| Bare-metal CoCo | [Deploying confidential containers on bare-metal servers, 1.12][rh12-cc] | Authoritative install/configure/update/uninstall/observe/troubleshoot flow for this repo's product line. |
| Compatibility | [1.12 compatibility page][rh12-compat] | Check live immediately before deployment; z-stream floors change. |
| Installation | [1.12 install chapter][rh12-install] | Requires supported OCP, Trustee in trusted environment, and UEFI. |
| Observability | [1.12 observe chapter][rh12-observe] | OSC/Kata metrics and log access. |
| Troubleshooting | [1.12 troubleshoot chapter][rh12-troubleshoot] | Version-matched OSC must-gather and status/log guidance. |
| Trustee, connected | [Deploying Red Hat build of Trustee for bare-metal workloads, 1.12][rh12-trustee] | Product topology, Operator, `TrusteeConfig`, policies, RVPS, image signature keys, updates. A PDF search result dated the guide 2026-04-13. |
| Trustee, disconnected | [Deploying Red Hat build of Trustee in a disconnected environment, 1.12][rh12-trustee-disconnected] | VCEK cache, route, signatures/policy, RVPS, verification, and update. |
| Azure peer pods | [Deploying confidential containers on Microsoft Azure, 1.12][rh12-azure] | Do not generalize this support to other clouds. |
| ARO peer pods | [Deploying confidential containers on Azure Red Hat OpenShift, 1.12][rh12-aro] | Includes peer-pods config, initdata, PodVM image/pull secret, and `kata-remote`. |
| IBM Z peer pods | [Deploying confidential containers on IBM Z/LinuxONE with peer pods, 1.12][rh12-ibmz-peer] | Architecture-specific. |
| Current product set | [OSC 1.13 documentation][rh13-landing] | Newer than this repository's baseline; available by research date. |
| Current compatibility | [1.13 bare-metal compatibility][rh13-compat] | As observed 2026-08-26, includes revised OCP z-stream floors and current platform matrix. |
| Current Trustee | [Red Hat build of Trustee for bare-metal workloads, 1.13][rh13-trustee] | Trustee 1.2 line; includes Trustee must-gather and more lifecycle material. |
| Current upgrade | [Disconnected Trustee upgrade, 1.13][rh13-trustee-upgrade] | Explicitly requires RVPS regeneration/reapply after OCP or OSC upgrade. |
| Current production policy warning | [1.13 bare-metal configuration][rh13-config] | Restrictive Kata Agent policy; disable `ExecProcessRequest` at minimum. |
| Product lifecycle | [OpenShift Container Platform life cycle policy][ocp-lifecycle] | Validate that both workload and Trustee clusters remain supported. |
| Operator lifecycle | [OpenShift Operator life cycles][operator-lifecycle] | OSC rolling-stream support and upgrade planning. |
| Technology Preview policy | [Technology Preview scope][rh-tp-scope] | TP is not production support and might lack an upgrade path. |
| Support responsibility boundary | [Production support scope][rh-support-scope] | Distinguishes product diagnosis from customer design/policy ownership. |
| Current TP list | [OSC 1.13 Technology Previews][rh13-tp] | Recheck because feature status can change by release/z-stream. |

### CNCF Confidential Containers and Trustee — concepts and upstream capabilities

| Topic | Direct source | Version/date caveat |
|---|---|---|
| Overall design/components | [Design Overview][coco-design] | Last modified 2026-02-03; upstream rolling documentation. |
| Trust boundary | [Trust Model for Confidential Containers][coco-trust] | Defines trusted guest, untrusted host/control plane, API crossings, and out-of-scope DoS/side channels. |
| Actors/ownership | [Cloud Native Personas][coco-personas] | Last modified 2024-11-15; conceptual role model. |
| Hardware prerequisites | [Hardware Requirements][coco-hardware] | Last modified 2026-01-15; upstream charts do not configure host firmware/kernel. |
| Cluster prerequisites | [Cluster Setup][coco-cluster] | Last modified 2026-01-20; upstream Helm/containerd assumptions differ from OpenShift. |
| Upstream installation | [CoCo Helm Installation][coco-install] | Last modified 2026-01-20; do not use in place of OSC Operator steps. |
| Trustee overview | [Attestation with Trustee][coco-attestation] | Last modified 2025-12-19; KBS/AS/RVPS/CDH/AA glossary. |
| Trustee architecture | [Trustee Architecture][coco-attestation-architecture] | Last modified 2025-12-19; evidence, policy, token, plugin roles. |
| Trustee deployment choices | [Trustee Installation][coco-trustee-install] | Last modified 2026-07-21; upstream Helm/operator/Compose choices. |
| Guest-to-Trustee setup | [CoCo Setup][coco-setup] | Last modified 2026-04-28; annotation and initdata KBS URL patterns. |
| KBS resources | [Trustee Resources][coco-resources] | Last modified 2026-02-23; resource URI and provisioning mechanisms. |
| Policies | [Trustee Policies][coco-policies] | Three policy layers and default-policy cautions. |
| KBS wire flow | [KBS Attestation Protocol][trustee-kbs-protocol] | `main` branch; request/challenge/attestation/response and resource APIs. |
| KBS configuration/storage | [KBS Configuration][trustee-kbs-config] | `main` branch; storage backends, AS modes, plugins; rolling and potentially newer than Red Hat build. |
| Initdata integrity | [Initdata Specification][trustee-initdata] | `main` branch; explicitly provides integrity, not confidentiality. |
| AS-to-KBS token trust | [Attestation Token Verification][trustee-token] | `main` branch; production certificate trust vs insecure local examples. |
| Signed images | [Signed Images][coco-signed] | Upstream cosign/simple-signing workflow; confirm downstream registry/signature path. |
| Encrypted images | [Encrypted Images][coco-encrypted] | Last modified 2026-02-23; key-release and layer-decryption flow plus debugging. |
| Sealed secrets | [Sealed Secrets][coco-sealed] | Last modified 2026-07-31; newer upstream capability. |
| Explicit resource request | [Get Secret Resources][coco-get-resource] | Last modified 2025-07-04; CDH loopback API. |
| Registry authentication caveat | [Authenticated Registries][coco-registry-auth] | States credentials are currently exposed to host; use encrypted images as mitigation. |
| Troubleshooting | [CoCo Troubleshooting][coco-troubleshoot] | Upstream containerd-centric commands must be translated to supported OpenShift procedures. |
| Trustee source/release history | [Trustee repository][trustee-repo] | Follow a Red Hat-supported build, not `main`, for production product behavior. |
| Trustee Operator source | [Trustee Operator repository][trustee-operator] | Upstream CR evolution may differ from Red Hat Operator. |
| Guest components | [Guest Components repository][guest-components] | CDH, attestation agent, image-rs, ocicrypt-rs implementation source. |
| Peer pods | [Cloud API Adaptor repository][caa] | Upstream provider support is not equivalent to Red Hat support. |
| Charts | [Confidential Containers Charts][coco-charts] | Upstream installation packaging; not the OSC Operator. |

### Upstream release snapshot and drift risks

The following releases were current in the official repositories on **2026-08-26**. They are useful for
tracking upstream fixes, not for selecting binaries for OpenShift:

| Project | Upstream release observed | Product-use warning |
|---|---|---|
| Confidential Containers aggregate / charts | [`v0.22.0`][coco-release-022] / [charts `v0.22.0`][coco-charts-022], published 2026-07-28 | Red Hat packages and validates a downstream stack; do not replace it with the chart release. |
| Trustee / guest components | [Trustee `v0.21.0`][trustee-release-021] / [guest components `v0.21.0`][guest-release-021], published 2026-07-20 | `main` docs and CR/config schemas can be newer than Trustee 1.1/1.2. |
| Trustee Operator | [`v0.21.0`][trustee-operator-021], published 2026-08-10 | The upstream site still contains older Operator examples; use the Red Hat Operator guide. |
| Cloud API Adaptor | [`v0.22.0`][caa-release-022], published 2026-07-27 | Provider implementation does not establish Red Hat platform support. |
| Kata Containers | [`4.1.0`][kata-release-410], published 2026-08-21 | OSC ships its own supported Kata/RHCOS combination. |

The upstream chart quick start calls Helm the upstream install path, deprecates the old CoCo Operator,
and currently says upgrades are not yet supported. This is another reason not to transplant upstream
installation/lifecycle instructions into OpenShift. ([chart quick start][coco-chart-quickstart])

Kata published a high-severity Agent Policy advisory on 2026-08-20 affecting upstream versions through
4.0.0 and fixed in 4.1.0. This is an example of why policy, runtime, documentation, and errata must be
version-aligned; it does **not** establish which OSC versions are affected. Check Red Hat security
advisories for the supported product determination. ([Kata GHSA-fmg6-v47x-52wr][kata-policy-ghsa])

### Kata Containers and hardware roots

| Topic | Direct source | Use |
|---|---|---|
| Kata architecture | [Kata Containers Architecture][kata-architecture] | Shim/runtime, hypervisor, VSOCK, guest agent, one VM per pod. |
| Kata Kubernetes mapping | [Kubernetes support][kata-kubernetes] | Explicitly says Kata represents a kubelet pod as a VM. |
| Kata Agent policy | [How to use the Kata Agent policy][kata-policy] | Policy creation and confidential-host/guest trust properties. |
| Kata project/security framing | [Kata quick-start architecture][kata-quickstart] | Stronger isolation is a building block, not complete multi-tenancy. Rolling `main` documentation now discusses Kata 4.0; OSC packages its own supported stack. |
| AMD SNP overview | [AMD SEV-SNP attestation overview][amd-snp-attestation] | Evidence report, VCEK signing, public-key binding, root-of-trust verification. |
| AMD endorsement API | [AMD VCEK Certificate and KDS Interface Specification][amd-vcek] | Primary specification for VCEK contents and KDS retrieval. |
| AMD firmware ABI | [SEV-SNP Firmware ABI Specification][amd-snp-abi] | Primary platform/attestation field semantics; low-level reference. |
| AMD development reference | [AMDESE/AMDSEV][amdsev-repo] | BIOS/firmware readiness background; not a substitute for Red Hat server certification/support. |

## Security-boundary reminders for the final guide

- Everything on the host outside the enclave—including kubelet, CRI runtime, host kernel, and Kata
  shim—is untrusted for confidentiality in the upstream model, but it still controls availability.
- Confidential computing does not prevent the host/control plane from refusing to schedule or run a
  PodVM; denial of service is out of scope.
- Hardware side channels and platform-specific limitations are inherited from the selected TEE and are
  not universally solved by CoCo.
- TEE protection does not repair vulnerable or malicious application code. The workload provider and
  data owner must still trust the code and apply normal supply-chain, network, identity, storage, and
  application controls.
- `oc exec`, debug consoles, host-provided mounts/devices, observability agents, and application APIs
  all cross or affect the security boundary. Enable only what the approved workload requires.
- A Kubernetes object being named Secret does not mean its plaintext is confidential from cluster
  administrators. State exactly where plaintext exists for every secret path.

Sources: [upstream trust model][coco-trust], [upstream personas][coco-personas], and
[Red Hat 1.12 restrictive policy guidance][rh12-config].

[rh12-landing]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12
[rh12-release]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/release_notes/new-features-and-enhancements
[rh12-cc]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/index
[rh12-compat]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/cc-discover_metal-cc
[rh12-install]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/install-cc-overview_metal-cc
[rh12-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc
[rh12-observe]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/observe_metal-cc
[rh12-troubleshoot]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/troubleshoot_metal-cc
[rh12-trustee]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/index
[rh12-trustee-upgrade]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/update-trustee-overview_metal-trustee
[rh12-trustee-disconnected]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/index
[rh12-azure]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_microsoft_azure/index
[rh12-aro]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_microsoft_azure_red_hat_openshift/index
[rh12-ibmz-peer]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_ibm_z_and_ibm_linuxone_with_peer_pods/index
[rh13-landing]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13
[rh13-compat]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/cc-discover_metal-cc
[rh13-config]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/configure-cc-overview_metal-cc
[rh13-trustee]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/index
[rh13-trustee-upgrade]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/update-trustee-overview_metal-trustee-disconnected
[ocp-lifecycle]: https://access.redhat.com/support/policy/updates/openshift
[operator-lifecycle]: https://access.redhat.com/support/policy/updates/openshift_operators
[rh-tp-scope]: https://access.redhat.com/support/offerings/techpreview
[rh-support-scope]: https://access.redhat.com/support/offerings/production/soc
[rh13-tp]: https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/release_notes/technology-previews

[coco-design]: https://confidentialcontainers.org/docs/architecture/design-overview/
[coco-trust]: https://confidentialcontainers.org/docs/architecture/trust-model/trust-model/
[coco-personas]: https://confidentialcontainers.org/docs/architecture/trust-model/cloud-native-personas/
[coco-hardware]: https://confidentialcontainers.org/docs/getting-started/prerequisites/hardware/
[coco-cluster]: https://confidentialcontainers.org/docs/getting-started/prerequisites/software/
[coco-install]: https://confidentialcontainers.org/docs/getting-started/installation/
[coco-attestation]: https://confidentialcontainers.org/docs/attestation/
[coco-attestation-architecture]: https://confidentialcontainers.org/docs/attestation/architecture/
[coco-trustee-install]: https://confidentialcontainers.org/docs/attestation/installation/
[coco-setup]: https://confidentialcontainers.org/docs/attestation/coco-setup/
[coco-resources]: https://confidentialcontainers.org/docs/attestation/resources/
[coco-policies]: https://confidentialcontainers.org/docs/attestation/policies/
[coco-signed]: https://confidentialcontainers.org/docs/features/signed-images/
[coco-encrypted]: https://confidentialcontainers.org/docs/features/encrypted-images/
[coco-sealed]: https://confidentialcontainers.org/docs/features/sealed-secrets/
[coco-get-resource]: https://confidentialcontainers.org/docs/features/get-resource/
[coco-registry-auth]: https://confidentialcontainers.org/docs/features/authenticated-registries/
[coco-get-attestation]: https://confidentialcontainers.org/docs/features/get-attestation/
[coco-runtime-attestation]: https://confidentialcontainers.org/docs/features/runtime-attestation/
[coco-protected-storage]: https://confidentialcontainers.org/docs/features/protected-storage/
[coco-emptydir]: https://confidentialcontainers.org/docs/features/protected-storage/confidential-emptydir/
[coco-image-storage]: https://confidentialcontainers.org/docs/features/protected-storage/confidential-image-storage/
[coco-troubleshoot]: https://confidentialcontainers.org/docs/troubleshooting/
[trustee-kbs-protocol]: https://github.com/confidential-containers/trustee/blob/main/kbs/docs/kbs_attestation_protocol.md
[trustee-kbs-config]: https://github.com/confidential-containers/trustee/blob/main/kbs/docs/config.md
[trustee-initdata]: https://github.com/confidential-containers/trustee/blob/main/kbs/docs/initdata.md
[trustee-token]: https://github.com/confidential-containers/trustee/blob/main/kbs/docs/attestation_token_verification.md
[trustee-repo]: https://github.com/confidential-containers/trustee
[trustee-operator]: https://github.com/confidential-containers/trustee-operator
[guest-components]: https://github.com/confidential-containers/guest-components
[caa]: https://github.com/confidential-containers/cloud-api-adaptor
[coco-charts]: https://github.com/confidential-containers/charts
[coco-release-022]: https://github.com/confidential-containers/confidential-containers/releases/tag/v0.22.0
[coco-charts-022]: https://github.com/confidential-containers/charts/releases/tag/v0.22.0
[trustee-release-021]: https://github.com/confidential-containers/trustee/releases/tag/v0.21.0
[guest-release-021]: https://github.com/confidential-containers/guest-components/releases/tag/v0.21.0
[trustee-operator-021]: https://github.com/confidential-containers/trustee-operator/releases/tag/v0.21.0
[caa-release-022]: https://github.com/confidential-containers/cloud-api-adaptor/releases/tag/v0.22.0
[coco-chart-quickstart]: https://github.com/confidential-containers/charts/blob/main/QUICKSTART.md
[crio-10084]: https://github.com/cri-o/cri-o/issues/10084

[kata-architecture]: https://github.com/kata-containers/kata-containers/blob/main/docs/design/architecture/README.md
[kata-kubernetes]: https://github.com/kata-containers/kata-containers/blob/main/docs/design/architecture/kubernetes.md
[kata-policy]: https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-the-kata-agent-policy.md
[kata-quickstart]: https://github.com/kata-containers/kata-containers/blob/main/docs/quick-start-guide.md
[kata-release-410]: https://github.com/kata-containers/kata-containers/releases/tag/4.1.0
[kata-policy-ghsa]: https://github.com/kata-containers/kata-containers/security/advisories/GHSA-fmg6-v47x-52wr

[amd-snp-attestation]: https://docs.amd.com/api/khub/documents/Fs8c5rfhxC4nlZfXaZal0Q/content
[amd-vcek]: https://docs.amd.com/api/khub/documents/dWGhwYpo1Wv51rJN4d~47g/content
[amd-snp-abi]: https://docs.amd.com/api/khub/documents/NJQrpYY7KZGtlxDEdBGtzA/content
[amdsev-repo]: https://github.com/AMDESE/AMDSEV
