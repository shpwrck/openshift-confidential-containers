# Capability status and next experiments

Checked **2026-10-08**. The target is AMD CPU confidential containers with OSC 1.13.1 / Trustee 1.2.1 and OCP 4.20.39. Exact catalog/bundle/helper identities are recorded in [the release manifest](../install/release-manifest.json); unresolved entries block deployment. Latitude was retired after its private-network qualification failed. The active [Cherry trial](cherry-validation.md) has passed the Ubuntu and Agent-live RHCOS SNP checks, bidirectional private networking, private DNS/NTP/registry TLS, and Agent-live isolation probes. Mirroring completed, installed RHCOS SNP and host isolation passed, and the main API/etcd are available. Cluster health and guest proofs remain pending; no guest rung is validated for this release set.

## What changed enough to retest

**AMD remains the target.** The work focuses on repeatable SNP installation, VCEK refresh after firmware/TCB changes, strict Trustee setup and the higher workload rungs. Intel and GPU validation are outside this effort.

**Trustee lifecycle:** the current automation follows TrusteeConfig ownership and waits for generated configuration migration before editing it. It checks that the serving pods actually mount the expected configuration versions. Bootstrap and resource release are separate steps. See [the Trustee workflow](trustee-current.md) and [the downstream 1.2.1 source](https://github.com/openshift/trustee/tree/v1.2.1).

**Encrypted images:** [OpenShift CRI-O PR 82](https://github.com/openshift/cri-o/pull/82) merged into `release-5.0` on October 5, 2026, at 08:20 UTC (merge commit `694532bb98d6a89cf999cd2969ccda8d4db561d1`). This is progress on the host-side encrypted-layer pull blocker. It does not establish inclusion in OCP 4.20.39 or supported encrypted-image operation with OSC 1.13. The [5.0.0-rc.0 release record](https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/5.0.0-rc.0/release.txt) predates that merge. The experiment needs a payload containing the change, its actual RHCOS/CRI-O build identity, compatible OSC operands and the allow/deny/recovery result. The default release inventory remains on the supported CPU matrix.

Signed-image verification is not presented as a newly introduced OSC 1.13 capability. The unresolved local question is whether the selected registry serves signatures in a format the shipped guest image verifier can retrieve. A host-side `cosign verify` pass is necessary preparation, not the guest proof. On October 5, mirror-registry 2.0.12 accepted the signed control and host verification rejected the same-content unsigned control for a signature-specific reason. Guest enforcement remains pending. The historical minimal mirror-registry problem must be tested with the actual selected registry.

The [Miami restoration check](validation/latitude-mia2-signed-controls-2026-10-05.json)
also passed an unchanged rerun using the preserved image/signature digests and public key.
It did not transfer the private signing key or re-sign either control.

## Keep the measurements distinct

| Proof | Change made for the negative | What a pass establishes |
|---|---|---|
| `rung-kbs` | Use an ordinary runtime without the in-guest data hub | This workload's secret gate cannot complete outside the confidential runtime; it is not a remote KBS authentication attack test |
| `rung-initdata` | Append a harmless comment to the exact measured initdata bytes | The approved configuration digest matters; installed CPU/TCB checks are preserved |
| `rung-rvps` | Remove only `snp_launch_measurement` from the actual Trustee 1.2 RVPS map | Guest launch reference enforcement, independently of initdata binding |
| `rung-signed` | Use a distinct accessible unsigned/wrong-key image digest under the same guest policy | The guest rejects that image because of its signature |
| `air-gap` | Replace the selected worker's VCEK with a different certificate | Endorsement verification matters; it does not prove the network is disconnected |
| `rung-encrypted` | Change measured initdata while keeping the encrypted digest and key identifier | For a compatible experimental payload, key release depends on attested configuration |

The old July result described measured-initdata enforcement under rung B. Preserve it as historical initdata evidence; do not relabel it as a completed launch-measurement RVPS proof.

## Run a proof

First complete [Trustee setup](trustee-current.md), artifact resolution, workload namespace creation and [the current rig preflights](cherry-validation.md). Use only a disposable environment. The runner requires both its workload namespace and Trustee namespace to have `coco.openshift.io/disposable=true`, plus `COCO_DISPOSABLE_TEST=1`. It checks exact worker payload and successful OSC/Trustee CSVs before mutation. Co-location requires explicit lab selection; HTTP and omitted agent policy additionally require `TRUSTEE_PROFILE=Permissive`. Neither is evidence of customer isolation.

```bash
export WORKER_CONTEXT=validation-workers
export TRUSTEE_CONTEXT=validation-trustee
export COCO_DISPOSABLE_TEST=1
export TRUSTEE_PROFILE=Restricted
export KBS_URL=https://trustee.example.internal
export KBS_CA_FILE="$COCO_STATE_DIR/trustee-ca.pem"
export MIRROR_CA="$COCO_STATE_DIR/mirror-ca.pem"
export AGENT_POLICY_FILE="$COCO_STATE_DIR/approved-agent-policy.rego"
make test-rung WHICH=rung-kbs
make test-rung WHICH=rung-initdata
make test-rung WHICH=rung-rvps
```

Names above are examples; select the actual contexts and endpoint. Namespace marking is a deliberate setup step after verifying the target, not something the proof runner adds automatically. The agent policy must be reviewed for the workload, including blocking administrator `ExecProcessRequest`; merely providing a file does not prove its restrictions. Initdata is visible in the pod annotation: put resource references and public certificates there, not secrets. `INITDATA_FILE` reuses approved bytes exactly and checks that its image policy URI matches the selected rung. `EMIT_INITDATA=1` prints the bytes used by the renderer for measurement generation.

For rung C, run on a controller or bastion with `jq`, Skopeo and Cosign installed; mirror
preparation does not install the signing tools. The Miami host check used Skopeo 1.22.2 and
checksum-verified Cosign 2.6.5. See the [Skopeo setup instructions](release-resolution.md)
and record the selected Cosign binary's version and checksum before use.

Create the destination namespace and give the pushing account access before building. With
the default Quay paths, create organization `coco` and private repositories `rung-b` and
`rung-b-unsigned`. A missing namespace can return an authorization error even with valid
credentials; inspect it through authenticated registry administration rather than disabling
TLS or treating the error as signature rejection.

Supply the mirror's trusted CA/authentication and `COSIGN_PASSWORD` through the external
credential workflow, then build the signed and unsigned controls without encryption tooling:

```bash
make build-rung-signed
source "$COCO_STATE_DIR/rung-image-artifacts/rung-signed.env"
make verify-rung-signed-signature
```

Configure registry trust for both tools. The tested bastion used its own
`REGISTRY_AUTH_FILE=/root/.docker/config.json`, `DOCKER_CONFIG=/root/.docker` and
`SSL_CERT_FILE=/opt/mirror/ca/rootCA.pem`. For host verification it additionally set
`COSIGN_VERIFY_ARGS="--insecure-ignore-tlog=true --registry-cacert=/opt/mirror/ca/rootCA.pem --trusted-root=/path/to/prepared-trusted-root.json"`.
The public trusted-root file was prepared on the connected controller and transferred with
its recorded checksum. Explicit trust metadata avoids implicit TUF initialization; this host
check did not measure network isolation. Use the paths and credentials for the current mirror.

If `ARTIFACT_DIR` was overridden, source `rung-signed.env` from that directory instead. The
file selects the immutable image references, public key and artifact manifest. On the
explicitly selected Permissive lab, `make deploy-trustee` seeds and attaches the image policy
and public key, then waits for refreshed serving pods. For Restricted Trustee, provision
those resources through the approved procedure in [the Trustee guide](trustee-current.md).
Run `make test-rung WHICH=rung-signed` after configuration converges.

The generated lab policy requires the same signing key for both configured repositories,
using separate exact repository scopes by default. Custom `RUNG_SIGNED_POLICY_FILE` policies
must also cover both controls with the same signature requirement; a default-reject rule
outside the signed repository does not prove signature verification. The unsigned repository
must be readable and free of a signature from the selected key. A DNS, TLS, registry
authentication or invalid-image failure is inconclusive.

For the SNP endorsement test also supply `PROOF_NODE` and `VCEK_SECRET_NAME` for that worker. Record the selected host, firmware/TCB, VCEK source identity and certificate hash. A matching HWID alone is not enough to reuse a certificate after a TCB change.

Rung D is excluded from `all`. `EXPERIMENTAL_ENCRYPTED_IMAGES=1` permits its explicit experimental path only after the selected release inventory is resolved. It does not override release compatibility checks or make the current 4.20 payload support encrypted pulls. A future candidate experiment needs a separately reviewed matching inventory and workload/key policy. It must never be reported as a supported-product success from a skipped or failed test.

## Evidence and recovery

The runner writes a new protected directory under `$COCO_STATE_DIR/proofs/` for every attempt. `results.json` records source and implementation hashes, release inventory hash, cluster/operator identities, policy hashes, pod UIDs, control results and denial evidence hashes. Exit codes are `0` PASS, `1` FAIL and `3` INCOMPLETE. Proofs are never resumed from old PASS records.

A namespace lock prevents concurrent runners changing the same Trustee. Policy edits use UID/resourceVersion checks, preserve unrelated fields and retain protected recovery copies. The denied pod is removed before restoring policy so it cannot retry after the resource becomes available. Restored configuration must be served by new Ready Trustee pods before the recovery control. A cleanup/restoration failure cannot produce PASS. Do not remove a stale lock until the interrupted run's resources and recovery files have been inspected.

When the guest reports only a generic CDH error, the runner also checks protected
Trustee logs fetched since the negative pod's creation. It requires a specific
verifier or resource-policy failure beside the denied request from that pod's IP.
An unrelated client's error or an HTTP denial by itself cannot complete the proof.
Raw negative evidence remains outside the checkout; public receipts record hashes.

## Demos worth preparing

1. A repeatable installation checkpoint: run verification twice, showing that the second pass neither reinstalls the node nor regenerates unchanged assets.
2. Secret release followed by measured-initdata rejection and recovery, with no secret value printed in logs.
3. Actual RVPS reference removal and restoration, clearly distinguished from the initdata demo.
4. Signed versus unsigned guest pulls through the chosen registry, if transport validation succeeds.
5. SNP endorsement rejection and recovery with the selected worker pinned, alongside independent evidence that AMD KDS egress is blocked.

Keep encrypted images as an engineering experiment until a compatible payload and hardware evidence exist. Omit GPU material for this customer.
