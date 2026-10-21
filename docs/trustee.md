# Trustee setup

This workflow uses Trustee 1.2.1 on AMD SEV-SNP. Customer defaults are
**Restricted, HTTPS and a separate trust domain**. The completed
[lab proofs](validation.md) used co-located Permissive HTTP with enforcing
resource policy; they do not validate the customer topology.

Use Python 3.12+, the development requirements, `jq` and the selected `oc`.
Set `TRUSTEE_CONTEXT` explicitly. Keep credentials and generated files in external
`COCO_STATE_DIR` storage as described in the [quickstart](quickstart.md).

Trustee decides whether a confidential VM gets its secrets (see
[the attestation sequence](architecture.md#how-a-confidential-pod-gets-its-secrets)).
Setting it up means giving it three things: the AMD certificate for each approved
node (VCEK), the measurements a correct VM must report (reference values), and the
policies that say which resources a passing VM may receive. The steps below run
in this order:

```mermaid
flowchart TD
  Op[Install the Trustee Operator] --> TLS[Provision HTTPS and token-signing Secrets]
  TLS --> VCEK[Collect each node's VCEK into a Secret]
  VCEK --> Boot[apply-trustee.sh bootstrap]
  Boot --> Init[Freeze the workload initdata]
  Init --> Refs[gen-rvps-veritas.sh: launch measurement]
  Refs --> TCB[Add firmware levels and review the reference set]
  TCB --> CPU[render-measurement-policy.sh: bind the initdata hash]
  CPU --> Res[Write a default-deny resource policy and resource Secrets]
  Res --> Conf[apply-trustee.sh configure]
  Conf --> Tests[Capability tests]
```

## Bootstrap

Install the selected Trustee Operator on the intended cluster. Provision the namespace
and these Secrets through the customer's credential/certificate process:

- `kbs-https-cert`: endpoint TLS certificate/key (`tls.crt`, `tls.key`).
- `kbs-token-cert`: attestation token signing/trust certificate/key.
- VCEK Secrets for the approved workers. [Collection and refresh](maintenance.md#collateral-and-references)
  use current host/TCB evidence; collection does not publish Secrets automatically.

The TLS names can be overridden with `TRUSTEE_HTTPS_SECRET` and
`TRUSTEE_TOKEN_SECRET`. Rerunning bootstrap does not rotate these identities.

Collect each approved worker's VCEK, then publish the collected certificates as
Secrets. The collector names each worker's directory under
`$COCO_STATE_DIR/vcek-bundle` after its HWID (the chip ID, 128 lowercase hex
digits), and bootstrap needs those identities in `HWIDS`:

```bash
export TRUSTEE_CONTEXT=customer-trustee TRUSTEE_PROFILE=Restricted TRUSTEE_LAB=0 TEE=snp
make collect-vcek NODE='<worker-node>'   # uses WORKER_CONTEXT
make seed-vcek                           # uses TRUSTEE_CONTEXT
export HWIDS="$(ls "$COCO_STATE_DIR/vcek-bundle" | grep -E '^[0-9a-f]{128}$' | tr '\n' ' ')"
```

If the controller can't reach AMD's key server, collection stops after recording
the certificate URL. Run `scripts/collect-vcek.sh --download` on a connected
machine and copy the bundle back before `make seed-vcek`. Then bootstrap:

```bash
make preflight
scripts/apply-trustee.sh bootstrap
```

Use `RENDER_ONLY=1` to inspect TrusteeConfig without a cluster action. Bootstrap
waits for Operator-owned KbsConfig/ConfigMaps and migration markers, checks their
ownership, and selects SNP `OfflineStore`. It retains the cache path and existing
resource entries but attaches no new customer workload resources.

An independent older KbsConfig stops the workflow. This is a fresh bootstrap,
not an automatic Trustee 1.1 upgrade. See [customer planning](customer-planning.md)
before migrating an existing deployment. Do not delete configuration or set migration
markers by hand to bypass that check.

## Calculate the approved references

Freeze the exact workload initdata bytes, including the complete reviewed agent
policy. For the capability tests, the renderer prints the bytes the test workloads
use (set the same profile, CA and policy variables you will test with):

```bash
EMIT_INITDATA=1 make -s run-rung-kbs > "$COCO_STATE_DIR/initdata.toml"
```

Then generate launch references from the selected release artifacts:

```bash
PULL_SECRET="$COCO_STATE_DIR/credentials/pull-secret.json" \
  INITDATA="$COCO_STATE_DIR/initdata.toml" \
  OUT="$COCO_STATE_DIR/rvps-generated.yaml" \
  VERITAS_KERNEL_CMDLINE='<exact reviewed runtime command line>' \
  scripts/gen-rvps-veritas.sh
```

The tested coco-tools default omitted `agent.launch_process_timeout=6`, which was
present in the actual Kata launch string. Supply the reviewed full string; the
independently calculated launch value must match the verified guest quote.
Read the string from a running confidential VM, not from the Kata configuration
file, because the runtime adds parameters at launch. With any `kata-cc` pod
running on the worker (it doesn't need to attest), print its QEMU `-append` argument:

```bash
oc --context="$WORKER_CONTEXT" debug node/'<worker-node>' -- chroot /host sh -c \
  'for p in $(pgrep -f qemu); do tr "\0" "\n" < /proc/$p/cmdline | grep -A1 -x -- -append | tail -n 1; done'
```
Reference generation can need connected registry access; stage its results before isolation.

Review the output and build the **complete** approved reference set:

- Trustee 1.2 `reference_value` maps names to base64-encoded JSON records with
  `name`, UTC-seconds `expiration` and typed `value`. Malformed, duplicate or expired
  records are rejected.
- Add `snp_bootloader`, `snp_microcode`, `snp_snp_svn` and `snp_tee_svn` as integers
  from the approved platform/verified quote. The generator does not collect hardware TCB.
- Omit coco-tools 0.5.1's unused SHA-384 `init_data` record when binding SHA-256 initdata
  through the CPU-policy extension below.

Generating or observing a value does not approve it. Confirm its source, expected
platform and expiry before publication.

## Bind initdata and publish resource policy

The default CPU policy does not bind the complete initdata digest. Render the
extension from the actual vendor CPU policy and the generated ConfigMap name found
in `KbsConfig.spec.kbsAttestationPolicyConfigMapName`:

```bash
CPU_CM="$(oc --context="$TRUSTEE_CONTEXT" -n trustee-operator-system get kbsconfig \
  -o jsonpath='{.items[0].spec.kbsAttestationPolicyConfigMapName}')"
oc --context="$TRUSTEE_CONTEXT" -n trustee-operator-system get configmap "$CPU_CM" \
  -o jsonpath='{.data.default_cpu\.rego}' > "$COCO_STATE_DIR/default_cpu.rego"
BASE_CPU_POLICY_FILE="$COCO_STATE_DIR/default_cpu.rego" \
  CPU_CONFIGMAP_NAME="$CPU_CM" \
  scripts/render-measurement-policy.sh "$COCO_STATE_DIR/initdata.toml" \
  > "$COCO_STATE_DIR/cpu-policy.yaml"
```

Review and apply this ConfigMap in the Trustee context. It retains hardware and
launch appraisals and adds the initdata condition. Skip it when you are about to
run the capability tests: the `rung-initdata` test adds the same condition for its
own control workload and restores the original policy afterwards, and it refuses a
CPU policy that is already bound. A permanent binding is for a deployment that runs
one fixed workload.

Binding does not create the resource policy: that policy must default to deny and
require the relevant appraisals for each resource path. The Operator's own
restrictive policy does this for every resource, allowing a request only when the
hardware, executables and configuration appraisals are all affirming. It is the
template the Operator installs for the Restricted profile
([`resource-policy-restrictive.rego`](https://github.com/openshift/trustee-operator/blob/v1.2.1/config/templates/resource-policy-restrictive.rego)),
and the October lab enforced it. Its hardware appraisal needs the four firmware
records above in the reference set.

```bash
curl -fsSL -o "$COCO_STATE_DIR/resource-policy.rego" \
  https://raw.githubusercontent.com/openshift/trustee-operator/v1.2.1/config/templates/resource-policy-restrictive.rego
```

Provision workload-resource Secrets out of band. Their names/keys form
`kbs:///default/<secret>/<key>` identities. Then publish the reviewed resource
policy, complete reference set and explicit resource names:

```bash
TRUSTEE_RESOURCE_POLICY_FILE="$COCO_STATE_DIR/resource-policy.rego" \
  TRUSTEE_RVPS_FILE="$COCO_STATE_DIR/rvps-reviewed.yaml" \
  KBS_RESOURCE_NAMES='credential sample security-policy registry-configuration' \
  scripts/apply-trustee.sh configure
```

The RVPS input **replaces the active reference set**. Include all required records.
Configuration preserves unrelated fields/resources, publishes policy/references before
attaching names, and refreshes serving pods. It checks structural defaults and ownership;
the [allow/deny/recovery proofs](capability-status.md) establish enforcement.

Trustee 1.2.1 removes `oc rollout restart` annotations during reconciliation. The
shared refresh step replaces only identified Operator-owned pods with UID checks,
then verifies new Ready UIDs, current ConfigMap versions and mounts. Use
`scripts/refresh-trustee.py` after a separately applied CPU-policy change; do not
infer refresh from a sleep or an event.

## Disposable lab

The validated lab runs Trustee on the worker cluster in the Permissive profile
over HTTP, with the restrictive resource policy above enforcing. Use the same
VCEK, bootstrap, reference and configure steps, with these differences:

- Set `TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1` and the same context in
  `WORKER_CONTEXT` and `TRUSTEE_CONTEXT`. No HTTPS or token Secrets are needed.
- Configure runs the synthetic resource seeder, which Restricted mode never does.
  It builds the registry credential, registry configuration, image policies and a
  sample secret for the helper's mirror registry. Copy the mirror CA and password
  from the helper and point the seeder at them:

  ```bash
  ssh '<helper>' 'sudo cat /opt/mirror/ca/rootCA.pem' > "$COCO_STATE_DIR/mirror-ca.pem"
  ssh '<helper>' 'sudo cat /opt/mirror/mirror-admin-password' > "$COCO_STATE_DIR/mirror-password"
  export MIRROR_CA="$COCO_STATE_DIR/mirror-ca.pem"
  export MIRROR_PASSWORD_FILE="$COCO_STATE_DIR/mirror-password"
  ```

  `ARTIFACTORY_REGISTRY` (default `mirror.rig.local:8443`) and `MIRROR_USERNAME`
  (default `init`) match the Ansible defaults. Build the
  [signed test images](capability-status.md#signed-images) and source their env
  file first, so the seeder also publishes the signing key and the signed-image policy.
- The Operator's Permissive resource policy enforces no appraisal. Supply **both**
  the reviewed policy and reference files, and the resource list, as in Restricted
  mode. The lab's list is the seeder's resources:

  ```bash
  TRUSTEE_RESOURCE_POLICY_FILE="$COCO_STATE_DIR/resource-policy.rego" \
    TRUSTEE_RVPS_FILE="$COCO_STATE_DIR/rvps-reviewed.yaml" \
    KBS_RESOURCE_NAMES='regcred attestation-cert attestation-status sample credential security-policy registry-configuration sig-public-key' \
    scripts/apply-trustee.sh configure
  ```

  Leave out `sig-public-key` if you haven't built the signed images.

This does not change HTTP or token trust, or establish customer separation.
Continue with [capability tests](capability-status.md).

Implementation references: [Operator ownership/migration](https://github.com/openshift/trustee-operator/tree/v1.2.1/internal/controller)
and [reference-value format](https://github.com/openshift/trustee/blob/v1.2.1/rvps/src/reference_value.rs).
Installed CRDs/CSV and the resolved downstream images remain the deployment authority.
