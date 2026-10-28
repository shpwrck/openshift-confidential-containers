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
- Add `snp_bootloader`, `snp_microcode`, `snp_snp_svn` and `snp_tee_svn` as lists of
  integers (the CPU policy checks them with `in`) for the approved platforms. The
  generator does not collect hardware TCB. Each collected VCEK was requested for the
  node's reported TCB, so its URL carries the four values; `scripts/review-references.py`
  adds them from the bundle for every HWID in `HWIDS` and prints the result for review.
- Omit coco-tools 0.5.1's unused SHA-384 `init_data` record when binding SHA-256 initdata
  through the CPU-policy extension below (`--drop init_data`).

```bash
scripts/review-references.py "$COCO_STATE_DIR/rvps-generated.yaml" \
  "$COCO_STATE_DIR/rvps-reviewed.yaml" --drop init_data
```

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
over HTTP, with the restrictive resource policy above enforcing. It follows the
same steps as the sections above; the commands below are the complete lab
sequence, so you don't need to adapt the customer blocks. No HTTPS or token
Secrets are needed. `HELPER` and `NODE` are your helper login
(`bastion_ssh_user@bastion_ansible_host` from the rig file) and the node name
from `oc get nodes`.

1. Set the lab variables, collect the node's VCEK and check that the bundle holds
   only this node's chip ID. The count must be `1` on a single-node lab; a larger
   count means a certificate left from another machine, so remove that directory
   before you go on.

   ```bash
   export WORKER_CONTEXT=validation TRUSTEE_CONTEXT=validation
   export TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1 TEE=snp
   make collect-vcek NODE="$NODE"
   export HWIDS="$(ls "$COCO_STATE_DIR/vcek-bundle" | grep -E '^[0-9a-f]{128}$' | tr '\n' ' ')"
   echo "$HWIDS" | wc -w
   ```

2. Publish the certificate and bootstrap Trustee:

   ```bash
   make seed-vcek
   make preflight
   scripts/apply-trustee.sh bootstrap
   ```

3. Copy the mirror CA and password from the helper. The initdata, the resource
   seeder and the capability tests all use them, so export them before the next
   step. `ARTIFACTORY_REGISTRY` (default `mirror.rig.local:8443`) and
   `MIRROR_USERNAME` (default `init`) match the Ansible defaults.

   ```bash
   ssh "$HELPER" 'sudo cat /opt/mirror/ca/rootCA.pem' > "$COCO_STATE_DIR/mirror-ca.pem"
   ssh "$HELPER" 'sudo cat /opt/mirror/mirror-admin-password' > "$COCO_STATE_DIR/mirror-password"
   export MIRROR_CA="$COCO_STATE_DIR/mirror-ca.pem" MIRROR_PASSWORD_FILE="$COCO_STATE_DIR/mirror-password"
   ```

4. Write the test workloads' initdata, then start a throwaway `kata-cc` pod so you
   can read the guest kernel command line. The pod never attests; it only needs
   its VM to start, which takes about a minute. The namespace is only created the
   first time; a [lab reset](maintenance.md#reset-a-disposable-coco-lab) keeps it.

   ```bash
   EMIT_INITDATA=1 make -s run-rung-kbs > "$COCO_STATE_DIR/initdata.toml"
   oc --context="$WORKER_CONTEXT" get namespace coco-validation >/dev/null 2>&1 ||
     oc --context="$WORKER_CONTEXT" create namespace coco-validation
   RENDER_ONLY=1 POD_NAME=cmdline-probe make -s run-rung-kbs | oc --context="$WORKER_CONTEXT" create -f -
   ```

   Then print the command line, as in [Calculate the approved references](#calculate-the-approved-references),
   and remove the pod. Rerun the first command if it prints nothing yet.

   ```bash
   oc --context="$WORKER_CONTEXT" debug node/"$NODE" -- chroot /host sh -c \
     'for p in $(pgrep -f qemu); do tr "\0" "\n" < /proc/$p/cmdline | grep -A1 -x -- -append | tail -n 1; done'
   oc --context="$WORKER_CONTEXT" -n coco-validation delete pod cmdline-probe
   ```

5. Generate the launch reference on the controller. Veritas runs in podman and
   needs Red Hat registry access, so pull its image with your pull secret first
   (`pull_secret_src` in the rig file; write `~` out as your home directory).
   Paste the printed command line between the quotes:

   ```bash
   PULL_SECRET='<path to your pull secret>'
   podman pull --authfile "$PULL_SECRET" "$(python3 scripts/verify-release.py --get images.cocoTools.ref)"
   PULL_SECRET="$PULL_SECRET" INITDATA="$COCO_STATE_DIR/initdata.toml" \
     OUT="$COCO_STATE_DIR/rvps-generated.yaml" \
     VERITAS_KERNEL_CMDLINE='<printed command line>' \
     scripts/gen-rvps-veritas.sh
   ```

6. Build the reviewed reference set. The script adds the node's four firmware
   levels from its VCEK request (the CPU policy checks them against the guest's
   reported TCB), drops Veritas's unused SHA-384 `init_data` record and prints
   every record. Check that `snp_launch_measurement` is the one Veritas printed
   and that the firmware levels are the ones you approve for this node.

   ```bash
   scripts/review-references.py "$COCO_STATE_DIR/rvps-generated.yaml" \
     "$COCO_STATE_DIR/rvps-reviewed.yaml" --drop init_data
   ```

7. Build the [signed test images](capability-status.md#signed-images) and source
   their env file, so the seeder also publishes the signing key and the
   signed-image policy.

8. Download the restrictive resource policy (the Operator's Permissive policy
   enforces no appraisal) and configure. Configure runs the synthetic resource
   seeder, which Restricted mode never does: it builds the registry credential,
   registry configuration, image policies and a sample secret for the helper's
   mirror registry. Leave out `sig-public-key` if you skipped the signed images.

   ```bash
   curl -fsSL -o "$COCO_STATE_DIR/resource-policy.rego" \
     https://raw.githubusercontent.com/openshift/trustee-operator/v1.2.1/config/templates/resource-policy-restrictive.rego
   TRUSTEE_RESOURCE_POLICY_FILE="$COCO_STATE_DIR/resource-policy.rego" \
     TRUSTEE_RVPS_FILE="$COCO_STATE_DIR/rvps-reviewed.yaml" \
     KBS_RESOURCE_NAMES='regcred attestation-cert attestation-status sample credential security-policy registry-configuration sig-public-key' \
     scripts/apply-trustee.sh configure
   ```

Skip the CPU-policy binding: the `rung-initdata` test adds it for its own workload.
This does not change HTTP or token trust, or establish customer separation.
Continue with [capability tests](capability-status.md).

Implementation references: [Operator ownership/migration](https://github.com/openshift/trustee-operator/tree/v1.2.1/internal/controller)
and [reference-value format](https://github.com/openshift/trustee/blob/v1.2.1/rvps/src/reference_value.rs).
Installed CRDs/CSV and the resolved downstream images remain the deployment authority.
