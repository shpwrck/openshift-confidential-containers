# Capability tests

All five AMD CPU tests passed allow/deny/recovery on October 8, 2026, and again
after a clean CoCo software reinstall. See [validation results](validation.md)
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
| `isolation` | A private destination must answer at each layer | No public address or name is reachable from the node, an ordinary pod or a confidential guest, and `oc exec` into the guest is refused ([network isolation](#network-isolation)) |

Each proof uses a new positive workload, one controlled change, an attributable
denial, exact restoration and a successful recovery workload. Skips and unrelated
startup errors never count as passes.

## Prepare the environment

On the lab, [`make trustee-lab`](trustee.md#disposable-lab) prepares everything
the tests need and writes their settings to `$COCO_STATE_DIR/trustee-lab.env`.
Load it and run every test:

```bash
source scripts/env.sh
make proof-plan
make test-rung WHICH=all
```

`make proof-plan` lists the tests and marks the ones `WHICH=all` runs, without
touching the cluster. The run takes about 25 minutes and stops at the first test
that does not pass.

Each test pod prints PodSecurity `restricted` warnings and a warning about the
`node-role.kubernetes.io/master` selector when it is created. Both are expected:
the namespace only warns, and the selector, which the Operator's `kata-cc`
RuntimeClass adds on a single-node cluster, still matches the node.

Elsewhere, complete [Trustee setup](trustee.md) and
[guest registry setup](guest-images.md) first. The runner requires:

- `COCO_DISPOSABLE_TEST=1` and explicit worker/Trustee contexts.
- Workload and Trustee namespaces labeled `coco.openshift.io/disposable=true`,
  deliberately marked only after confirming they belong to this test environment.
- The exact selected worker payload and successful OSC/Trustee CSVs.
- Endpoint/mirror trust and the reviewed complete agent policy. Customer mode uses
  Restricted HTTPS; co-location requires explicit `TRUSTEE_LAB=1`.

Create the workload namespace, then mark it and the Trustee namespace as disposable
once you have confirmed both belong to this test environment:

```bash
oc --context="$WORKER_CONTEXT" create namespace coco-validation
oc --context="$WORKER_CONTEXT" label namespace coco-validation coco.openshift.io/disposable=true
oc --context="$TRUSTEE_CONTEXT" label namespace trustee-operator-system coco.openshift.io/disposable=true
```

`KBS_URL` defaults to the in-cluster HTTP service, which only the lab accepts.
Customer mode instead uses the following inputs (replace all example names/paths):

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
Derive the Secret from that worker's HWID, as above, so it matches the KbsConfig
cache entry; do not select a random peer.

`INITDATA_FILE` reuses approved bytes and checks the rung's image-policy URI.
`EMIT_INITDATA=1` prints the renderer's bytes for reference preparation. Initdata is
visible in the pod annotation: include public certificates and resource references,
never secret values. The agent policy must permit the workload while denying
administrator `ExecProcessRequest`.

## Signed images

Signing is not a newly introduced OSC 1.13 feature. The October 8 test establishes
guest enforcement with the selected payload and mirror-registry 2.0.12.

On the lab, `make trustee-lab` builds these images on the helper. Elsewhere, build
on a machine with Skopeo and Cosign that reaches the registry by the name the
guest uses, because the signature records that name. `SSL_CERT_FILE` makes both
tools trust the registry's CA for that one command:

```bash
SSL_CERT_FILE="$MIRROR_CA" skopeo login -u init --password-stdin mirror.rig.local:8443 < "$MIRROR_PASSWORD_FILE"
SSL_CERT_FILE="$MIRROR_CA" cosign login -u init --password-stdin mirror.rig.local:8443 < "$MIRROR_PASSWORD_FILE"
```

The first build creates the signing key pair in
`$COCO_STATE_DIR/rung-image-artifacts`, protected by a password you choose. Run
this line on its own; it waits silently for the password:

```bash
read -rs COSIGN_PASSWORD && export COSIGN_PASSWORD
```

Then build and load the image references:

```bash
SSL_CERT_FILE="$MIRROR_CA" make build-rung-signed
source "$COCO_STATE_DIR/rung-image-artifacts/rung-signed.env"
```

The build creates the `coco/rung-b` and `coco/rung-b-unsigned` repositories on the
first push and ends with the checks of `make verify-rung-signed-signature` (run
that later with the same `SSL_CERT_FILE`): the signed image verifies with the key,
and the unsigned control is rejected for a missing signature. Both repositories
can hold the same image digest; the signature is stored per repository.

Use the selected `ARTIFACT_DIR` if overridden. The env file supplies immutable
signed/unsigned images, public key and manifest. Configure the guest image policy
and signing-key resources through [Trustee setup](trustee.md), then run
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

`make test-rung WHICH=all` runs the five CPU tests with fresh controls, then the
isolation checks; it excludes encryption. It does **not** reinstall CoCo;
[maintenance](maintenance.md) covers that separate operation.

## Network isolation

The `isolation` test checks egress at three layers: the node, an ordinary pod and
a confidential guest. At each layer a private destination must answer, so that a
blocked result cannot come from a broken probe, and then a public address
(`1.1.1.1`) and a public name (`quay.io`) must both fail:

| Layer | How it probes | Private destination |
|---|---|---|
| Node | `oc debug node/$PROOF_NODE` | The mirror registry's `/v2/` endpoint (`401` without credentials) |
| Ordinary pod | A short-lived pod in the workload namespace | The in-cluster Trustee service |
| Confidential guest | A `rung-kbs` workload whose application runs the probes. It only starts after attestation and pulls its image inside the VM, so a started pod is the positive control. The agent policy blocks `oc logs`, so it reports through its exit code | The in-cluster Trustee service |

Then it starts another `rung-kbs` workload and runs `oc exec` into it, which the
agent policy must refuse with `ExecProcessRequest is blocked by policy`. The
report records each layer's results. Repeat the test after every reboot or
rollout with `make test-rung WHICH=isolation`.

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
