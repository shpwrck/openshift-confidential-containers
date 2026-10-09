# Capability tests

All five AMD CPU tests passed allow/deny/recovery on October 8, 2026, and again
after a clean CoCo software reinstall. See [validation results](validation/README.md)
for exact versions, receipts and limits. The rig is retired; new runs need new inputs.

## What each test proves

| Test | Negative control | Meaning of a pass |
|---|---|---|
| `rung-kbs` | Ordinary runtime without the guest data hub | This workload's secret gate cannot complete outside the confidential runtime; not a remote KBS authentication attack test |
| `rung-initdata` | Append a harmless comment to measured initdata | Changed bytes are rejected while CPU/TCB checks remain active |
| `rung-rvps` | Remove only `snp_launch_measurement` from Trustee's actual RVPS map | Launch-reference enforcement, independent of initdata binding |
| `rung-signed` | Pull a distinct accessible unsigned repository under the same key requirement | Guest signature enforcement; transport/authentication failures are inconclusive |
| `air-gap` | Substitute the selected worker's VCEK certificate | Endorsement enforcement; network isolation is tested separately |
| `rung-encrypted` | Change initdata while retaining the encrypted image/key identifier | Experimental key-release test; **not validated** on the selected payload |

Each proof uses a new positive workload, one controlled change, an attributable
denial, exact restoration and a successful recovery workload. Skips and unrelated
startup errors never count as passes.

## Prepare the environment

Complete [Trustee setup](trustee-current.md) and [guest registry setup](guest-images.md).
Choose the actual contexts and namespaces. The runner requires:

- `COCO_DISPOSABLE_TEST=1` and explicit worker/Trustee contexts.
- Workload and Trustee namespaces labeled `coco.openshift.io/disposable=true`,
  deliberately marked only after confirming they belong to this test environment.
- The exact selected worker payload and successful OSC/Trustee CSVs.
- Endpoint/mirror trust and the reviewed complete agent policy. Customer mode uses
  Restricted HTTPS; co-location requires explicit `TRUSTEE_LAB=1`.

For the validated co-located lab, set the same worker/Trustee context,
`TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1`, the actual HTTP endpoint and mirror CA.
Publish the enforcing resource policy/references before testing. Customer mode
instead uses the following inputs (replace all example names/paths):

```bash
export WORKER_CONTEXT=validation-workers TRUSTEE_CONTEXT=validation-trustee
export COCO_DISPOSABLE_TEST=1 TRUSTEE_PROFILE=Restricted TRUSTEE_LAB=0
export KBS_URL=https://trustee.example.internal
export KBS_CA_FILE="$COCO_STATE_DIR/trustee-ca.pem"
export MIRROR_CA="$COCO_STATE_DIR/mirror-ca.pem"
export AGENT_POLICY_FILE="$COCO_STATE_DIR/approved-agent-policy.rego"
make proof-plan
make test-rung WHICH=rung-kbs WORKLOAD_NS=coco-validation NS=trustee-operator-system
```

`WORKLOAD_NS` selects the workloads; Make's `NS` selects Trustee. For the SNP
endorsement test, also set `PROOF_NODE` and that worker's `VCEK_SECRET_NAME`.
Derive the Secret from the actual KbsConfig cache entry; do not select a random peer.

`INITDATA_FILE` reuses approved bytes and checks the rung's image-policy URI.
`EMIT_INITDATA=1` prints the renderer's bytes for reference preparation. Initdata is
visible in the pod annotation: include public certificates and resource references,
never secret values. The agent policy must permit the workload while denying
administrator `ExecProcessRequest`.

## Signed images

Signing is not a newly introduced OSC 1.13 feature. The October 8 test establishes
guest enforcement with the selected payload and mirror-registry 2.0.12.
Prepare Skopeo, Cosign, registry CA/authentication and the external signing-key
password. Create writable destination repositories before building.

```bash
make build-rung-signed
source "$COCO_STATE_DIR/rung-image-artifacts/rung-signed.env"
make verify-rung-signed-signature
```

Use the selected `ARTIFACT_DIR` if overridden. The env file supplies immutable
signed/unsigned images, public key and manifest. Configure the guest image policy
and signing-key resources through [Trustee setup](trustee-current.md), then run
`make test-rung WHICH=rung-signed`.

Both repositories must be readable and covered by the **same signing-key requirement**.
The unsigned repository must lack a signature from that key. Host `cosign verify`
is preparation; only the guest test proves guest enforcement. Stage Cosign trust
metadata for disconnected verification rather than relying on an implicit TUF fetch.

## Evidence and recovery

Each attempt writes protected `$COCO_STATE_DIR/proofs/<new-run>/results.json`,
recovery files and denial evidence. The report records source/release identities,
policy hashes, pod UIDs and control results. Exit codes: `0` PASS, `1` FAIL, `3` INCOMPLETE.

A Trustee namespace lock prevents concurrent mutations. Changes check UID/resourceVersion
and preserve unrelated fields. The denied pod is deleted before restoration; restored
configuration must be served by new Ready pods before recovery. If restoration fails,
inspect the recovery files and actual resources before removing the lock. A generic
guest error requires a specific, matching Trustee denial from that guest/time window.

`make test-rung WHICH=all` runs all five CPU tests with fresh controls and excludes
encryption. It does **not** reinstall CoCo; [maintenance](maintenance.md) covers
that separate operation. Test host, ordinary-pod and guest isolation independently,
with working private-service controls and a deliberately failing probe calibration.

## Encryption and demos

The tested OCP 4.20.39 CRI-O lacks the VM image-service change merged in
[OpenShift CRI-O PR 82](https://github.com/openshift/cri-o/pull/82) for `release-5.0`
on October 5. That merge does not establish encrypted-image support in OSC 1.13
on this payload. A compatible payload, matching OSC inventory and key-provider
preparation are still needed before an end-to-end test.

`EXPERIMENTAL_ENCRYPTED_IMAGES=1` permits an explicitly selected experiment;
it does not bypass compatibility checks or add encryption to `all`.

Useful demos on a future rig are initdata tamper/recovery, actual RVPS reference
removal/recovery, and signed versus unsigned guest pulls. Show their attributable
denials and evidence reports. Do not present an encryption or customer-upgrade demo
as validated by the completed lab.
