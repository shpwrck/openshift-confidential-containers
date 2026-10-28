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

Each proof uses a new positive workload, one controlled change, an attributable
denial, exact restoration and a successful recovery workload. Skips and unrelated
startup errors never count as passes.

## Prepare the environment

Complete [Trustee setup](trustee.md) and [guest registry setup](guest-images.md).
Choose the actual contexts and namespaces. The runner requires:

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

For the validated co-located lab, publish the enforcing resource policy and
references first ([Trustee setup](trustee.md#disposable-lab)), then run every test:

```bash
export WORKER_CONTEXT=validation TRUSTEE_CONTEXT=validation
export COCO_DISPOSABLE_TEST=1 TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1
export MIRROR_CA="$COCO_STATE_DIR/mirror-ca.pem"
export PROOF_NODE='<worker-node>'
export VCEK_SECRET_NAME="$(python3 scripts/lib/trustee_config.py mounts --hwids "$HWIDS" | jq -r '.[0].secretName')"
source "$COCO_STATE_DIR/rung-image-artifacts/rung-signed.env"   # from the signed image build below
make proof-plan
make test-rung WHICH=all
```

Each test pod prints PodSecurity `restricted` warnings and a warning about the
`node-role.kubernetes.io/master` selector when it is created. Both are expected:
the namespace only warns, and the selector, which the Operator's `kata-cc`
RuntimeClass adds on a single-node cluster, still matches the node.

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
Build on a machine with Skopeo and Cosign that can reach the registry. In the
lab that is the controller, through a tunnel to the helper's mirror; `HELPER`,
`MIRROR_CA` and `MIRROR_PASSWORD_FILE` are as in
[Trustee setup](trustee.md#disposable-lab). The lab mirror creates the
`coco/rung-b` and `coco/rung-b-unsigned` repositories on the first push.
`SSL_CERT_FILE` makes both tools trust the mirror's CA for that one command:

```bash
sudo dnf install -y skopeo cosign
ssh -f -N -L 8443:mirror.rig.local:8443 "$HELPER"
echo '127.0.0.1 mirror.rig.local' | sudo tee -a /etc/hosts
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

The build ends with the checks of `make verify-rung-signed-signature` (run that
later with the same `SSL_CERT_FILE`): the signed image verifies with the key, and
the unsigned control is rejected for a missing signature. Both repositories can
hold the same image digest; the signature is stored per repository.

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

`make test-rung WHICH=all` runs all five CPU tests with fresh controls and excludes
encryption. It does **not** reinstall CoCo; [maintenance](maintenance.md) covers
that separate operation. Test host, ordinary-pod and guest isolation independently
([network isolation](#network-isolation)).

## Network isolation

Isolation is a separate check from the capability tests, made at three layers: the
node, an ordinary pod and a confidential guest. At each layer public addresses and
names must be unreachable while a private destination answers, so a blocked result
can't come from a broken probe. Repeat the checks after every reboot or rollout.
The commands use the repository's default mirror name.

```bash
NODE='<worker-node>'
# Node: the mirror answers over TLS (401 without credentials); public TCP and names fail.
oc --context="$WORKER_CONTEXT" debug node/"$NODE" -- chroot /host sh -c '
  curl -sS -m 10 -o /dev/null -w "mirror %{http_code}\n" https://mirror.rig.local:8443/v2/
  curl -sS -m 10 -o /dev/null https://1.1.1.1 && echo FAIL-public-tcp || echo ok-no-public-tcp
  curl -sS -m 10 -o /dev/null https://quay.io && echo FAIL-public-name || echo ok-no-public-name'

# Ordinary pod: the in-cluster Trustee service answers; public TCP and names fail.
# The pause lets oc attach before the first line prints.
oc --context="$WORKER_CONTEXT" -n coco-validation run egress-probe --rm -i --restart=Never \
  --image="$(python3 scripts/verify-release.py --get images.ubiMinimal.ref)" -- sh -c 'sleep 5
  curl -sS -m 10 -o /dev/null -w "kbs %{http_code}\n" http://kbs-service.trustee-operator-system.svc:8080/
  curl -sS -m 10 -o /dev/null https://1.1.1.1 && echo FAIL-public-tcp || echo ok-no-public-tcp
  curl -sS -m 10 -o /dev/null https://quay.io && echo FAIL-public-name || echo ok-no-public-name'
```

For the guest, render the `rung-kbs` workload and replace its application command
with the same probes. The pod only starts after attestation, and its image comes
from the private registry inside the VM, so a started pod is the positive control.
The guest's agent policy blocks `oc logs` as well as `oc exec`, so the probe reports
through its exit code instead:

```bash
RENDER_ONLY=1 POD_NAME=guest-probe make -s run-rung-kbs > "$COCO_STATE_DIR/guest-probe.yaml"
python3 - "$COCO_STATE_DIR/guest-probe.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
pod = yaml.safe_load(open(path))
pod["spec"]["containers"][0]["command"] = ["/bin/sh", "-c",
    "code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://kbs-service.trustee-operator-system.svc:8080/); "
    "[ \"$code\" != 000 ] || exit 10; "
    "curl -s -m 10 -o /dev/null https://1.1.1.1 && exit 11; "
    "curl -s -m 10 -o /dev/null https://quay.io && exit 12; exit 0"]
yaml.safe_dump(pod, open(path, "w"), sort_keys=False)
PY
oc --context="$WORKER_CONTEXT" apply -f "$COCO_STATE_DIR/guest-probe.yaml"
until phase="$(oc --context="$WORKER_CONTEXT" -n coco-validation get pod guest-probe -o jsonpath='{.status.phase}')" &&
  [[ "$phase" == Succeeded || "$phase" == Failed ]]; do sleep 10; done
echo "$phase exit=$(oc --context="$WORKER_CONTEXT" -n coco-validation get pod guest-probe \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
oc --context="$WORKER_CONTEXT" -n coco-validation delete pod guest-probe
```

A pass is a numeric HTTP status from the private destination and `ok-` on every
other line at the node and pod layers, and `Succeeded exit=0` for the guest.
`000`, any `FAIL-` line or a guest exit of 10 (no private answer), 11 (public TCP)
or 12 (public name) needs investigation.

While a confidential pod is running, `oc exec` into it must also be refused by the
agent policy:

```bash
RENDER_ONLY=1 POD_NAME=exec-probe make -s run-rung-kbs | oc --context="$WORKER_CONTEXT" create -f -
oc --context="$WORKER_CONTEXT" -n coco-validation wait pod/exec-probe --for=condition=Ready --timeout=10m
oc --context="$WORKER_CONTEXT" -n coco-validation exec exec-probe -c app -- true; echo "exec exit=$?"
oc --context="$WORKER_CONTEXT" -n coco-validation delete pod exec-probe
```

A pass is an error that says `ExecProcessRequest is blocked by policy` and a
non-zero `exec exit`.

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
