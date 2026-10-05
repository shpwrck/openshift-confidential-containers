# Trustee 1.2 bootstrap, configuration and proof

This AMD SEV-SNP workflow targets the version selected by `install/release-manifest.json`.
Its Operator and catalog identities are resolved; rerun the release gate before deployment. It has offline tests; no hardware appraisal or customer upgrade is claimed.
Python 3.12+, `requirements-dev.txt`, `jq`, and the selected `oc` are required.

## Ownership and upgrade boundary

Use `scripts/apply-trustee.sh`, with an explicit `TRUSTEE_CONTEXT` for the customer.
The default `Restricted` TrusteeConfig generates its KbsConfig, configuration and
CPU/GPU/resource/RVPS ConfigMaps. The script resolves those names through the actual
KbsConfig, waits for all five migration markers and validates their owning UID.
It then changes only the intended fields with resource-version preconditions.

An existing independent KbsConfig is refused. This is a fresh bootstrap and
configuration entry point, **not an automatic 1.1-to-1.2 upgrade**. Before upgrading
an existing deployment, capture its CR/CSV/CRD identities, policies, resources,
collateral, TLS and signer identities in protected storage outside Homelab; rehearse
the product migration in an isolated clone. Do not delete configuration or set
migration annotations by hand to bypass the guard. Operator 1.2 migration can
replace old policy/configuration maps, and its plugin merge does not preserve all
custom verifier settings.

The script preserves unrelated TOML and existing KbsConfig resource/cache entries.
It never reassigns an existing TrusteeConfig profile or TLS references. Pruning old
resource references and rotating TLS/signing identities need a separate reviewed
procedure. There is one Trustee deployment/service identity per namespace.

## Customer bootstrap

First resolve the selected artifact inventory and pass:

```sh
python3 scripts/verify-release.py --require-resolved
```

Provision the namespace, Operator and these resources through the approved
credential/certificate process outside the checkout:

- `kbs-https-cert`: a TLS Secret with `tls.crt` and `tls.key` for the Trustee endpoint.
- `kbs-token-cert`: a TLS Secret with `tls.crt` and `tls.key` for token signing/trust.
- SNP: collected VCEK Secrets for the actual approved `HWIDS`.

The two TLS Secret names can be selected with `TRUSTEE_HTTPS_SECRET` and
`TRUSTEE_TOKEN_SECRET`. These are inputs to Operator-generated Secret identities;
rerunning the script is not a certificate rotation mechanism.

Render the nonsecret TrusteeConfig without any cluster action:

```sh
TRUSTEE_CONTEXT=customer-trustee RENDER_ONLY=1 scripts/apply-trustee.sh bootstrap
```

For SNP, set the actual 128-hex-digit HWIDs, then bootstrap:

```sh
export TRUSTEE_CONTEXT=customer-trustee TRUSTEE_PROFILE=Restricted TEE=snp
export HWIDS='<approved-hwid>'
scripts/apply-trustee.sh bootstrap
```

SNP bootstrap selects only `OfflineStore`, retaining the existing cache path.
The workflow does not download new collateral or renew it automatically.
Bootstrap attaches no new customer workload-resource names. Generated Operator
sample resources and any previously attached resource names remain present.

## Publish the reviewed policy and references

Freeze the final initdata first. Generate references on the selected hardware
using the resolved coco-tools image and keep registry credentials outside Homelab:

```sh
PULL_SECRET="$HOME/.local/state/coco/pull-secret.json" \
  INITDATA=/path/to/frozen-initdata.toml OUT=/path/to/reviewed-rvps.json \
  scripts/gen-rvps-veritas.sh
```

The generator accepts Veritas records only when they conform to Trustee 1.2:
`reference_value` maps each record name to base64 of the complete JSON record,
including `name`, UTC-seconds `expiration`, and typed `value`. It rejects duplicate,
empty, malformed or expired records. Generation alone does not publish references
or prove that they match the installed CPU policy.

Provide an approved resource policy that defaults to deny and enforces the required
hardware, executable and configuration appraisals for the intended resource paths.
Provision the corresponding resource Secrets out of band, retaining their names and
keys because these determine `kbs:///default/<secret>/<key>` identities. Then run:

```sh
TRUSTEE_RESOURCE_POLICY_FILE=/path/to/approved-resource-policy.rego \
  TRUSTEE_RVPS_FILE=/path/to/reviewed-rvps.json \
  KBS_RESOURCE_NAMES='credential sample security-policy sig-public-key' \
  scripts/apply-trustee.sh configure
```

The supplied RVPS set replaces the active reference set; include every approved
record required by this deployment. The script checks native Restricted TLS/token
references, conservative CPU defaults, and core platform reference names. These are
structural checks, not a Rego execution proof. A reviewed custom CPU policy outside
the recognized structure stops for review rather than being overwritten.

Configuration publishes approved policy/references before attaching resource names,
preserves unrelated resource/cache entries, and rotates serving pods. Completion
requires current ConfigMap resource-version annotations, resource/cache mounts and
new Ready pod UIDs. This includes the Secret converter lifecycle; an event alone
does not prove refreshed resource contents are served.

## Initdata binding and isolated validation

The installed default CPU policy does not itself bind a complete initdata digest.
To render an extension, supply the actual reviewed CPU policy and the actual
ConfigMap name from `KbsConfig.spec.kbsAttestationPolicyConfigMapName`:

```sh
BASE_CPU_POLICY_FILE=/path/to/installed-default_cpu.rego \
  CPU_CONFIGMAP_NAME=<actual-generated-cpu-configmap> \
  scripts/render-measurement-policy.sh /path/to/frozen-initdata.toml
```

This emits only a CPU ConfigMap, preserving vendor hardware/launch/configuration
appraisals and adding an initdata condition. It emits no resource policy. The
resource policy must enforce the resulting appraisal. Validate the measured byte
contract with the allow/tamper/recovery proof before depending on it. Signature
verification of container images is a separate guest policy; encryption remains an
explicit experimental path.

Use the proof runner only in a dedicated environment with
`COCO_DISPOSABLE_TEST=1`, explicit worker/Trustee contexts, and both namespaces
labeled `coco.openshift.io/disposable=true`. It snapshots protected recovery data
outside the checkout and requires attributable denial plus restoration/recovery.
A `Permissive` lab result is not evidence for the customer's Restricted profile.

## Disposable lab resources

A co-located disposable lab must explicitly select
`TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1`; the seeder additionally checks the actual
TrusteeConfig profile. Use the same bootstrap/configure order. The lab seeder keeps
existing omitted Secret keys, including signed-image policy keys, on a plain rerun.
The seeder loads the external VCEK bundle. Customer mode never invokes the demonstration seeder.

## Implementation references

- [Operator 1.2.1 migration](https://github.com/openshift/trustee-operator/blob/v1.2.1/internal/controller/migration.go)
- [TrusteeConfig generation and ownership](https://github.com/openshift/trustee-operator/blob/v1.2.1/internal/controller/trusteeconfig_controller.go)
- [KbsConfig serving mounts and configuration versions](https://github.com/openshift/trustee-operator/blob/v1.2.1/internal/controller/kbsconfig_controller.go)
- [Restricted CPU policy](https://github.com/openshift/trustee-operator/blob/v1.2.1/config/templates/ear_default_attestation_policy_cpu.rego)
- [Target reference-value type](https://github.com/openshift/trustee/blob/v1.2.1/rvps/src/reference_value.rs)

Installed CRDs/CSV and resolved downstream images remain the deployment authority;
a source tag alone does not establish a supported catalog inventory or hardware proof.
