# Trustee setup

This workflow uses Trustee 1.2.1 on AMD SEV-SNP. Customer defaults are
**Restricted, HTTPS and a separate trust domain**. The completed
[lab proofs](validation/README.md) used co-located Permissive HTTP with enforcing
resource policy; they do not validate the customer topology.

Use Python 3.12+, the development requirements, `jq` and the selected `oc`.
Set `TRUSTEE_CONTEXT` explicitly. Keep credentials and generated files in external
`COCO_STATE_DIR` storage as described in the [quickstart](current-quickstart.md).

## Bootstrap

Install the selected Trustee Operator on the intended cluster. Provision the namespace
and these Secrets through the customer's credential/certificate process:

- `kbs-https-cert`: endpoint TLS certificate/key (`tls.crt`, `tls.key`).
- `kbs-token-cert`: attestation token signing/trust certificate/key.
- VCEK Secrets for the approved workers. [Collection and refresh](maintenance.md#collateral-and-references)
  use current host/TCB evidence; collection does not publish Secrets automatically.

The TLS names can be overridden with `TRUSTEE_HTTPS_SECRET` and
`TRUSTEE_TOKEN_SECRET`. Rerunning bootstrap does not rotate these identities.
Set `HWIDS` to the approved lowercase 128-hex-digit worker identities:

```bash
export TRUSTEE_CONTEXT=customer-trustee TRUSTEE_PROFILE=Restricted TRUSTEE_LAB=0 TEE=snp
export HWIDS='<approved-hwid>'
make preflight
scripts/apply-trustee.sh bootstrap
```

Use `RENDER_ONLY=1` to inspect TrusteeConfig without a cluster action. Bootstrap
waits for Operator-owned KbsConfig/ConfigMaps and migration markers, checks their
ownership, and selects SNP `OfflineStore`. It retains the cache path and existing
resource entries but attaches no new customer workload resources.

An independent older KbsConfig stops the workflow. This is a fresh bootstrap,
not an automatic Trustee 1.1 upgrade. See [customer planning](design/customer-scoping.md)
before migrating an existing deployment. Do not delete configuration or set migration
markers by hand to bypass that check.

## Calculate the approved references

Freeze the exact workload initdata bytes, including the complete reviewed agent
policy. Then generate launch references from the selected release artifacts:

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
BASE_CPU_POLICY_FILE="$COCO_STATE_DIR/default_cpu.rego" \
  CPU_CONFIGMAP_NAME='<actual-generated-cpu-configmap>' \
  scripts/render-measurement-policy.sh "$COCO_STATE_DIR/initdata.toml" \
  > "$COCO_STATE_DIR/cpu-policy.yaml"
```

Review and apply this ConfigMap in the Trustee context. It retains hardware and
launch appraisals and adds the initdata condition. It does not create the resource
policy: that policy must default to deny and require the relevant appraisals for
each resource path.

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

For a co-located test, explicitly set `TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1`
and use the same bootstrap/configure sequence. Configure invokes the synthetic
resource seeder; Restricted mode never does.

The ordinary Permissive resource policy does not enforce CPU appraisals. For
initdata/RVPS proofs, supply **both** enforcing policy and reviewed reference files,
plus `KBS_RESOURCE_NAMES`. This does not change HTTP/token trust or establish
customer separation. Continue with [capability tests](capability-status.md).

Implementation references: [Operator ownership/migration](https://github.com/openshift/trustee-operator/tree/v1.2.1/internal/controller)
and [reference-value format](https://github.com/openshift/trustee/blob/v1.2.1/rvps/src/reference_value.rs).
Installed CRDs/CSV and the resolved downstream images remain the deployment authority.
