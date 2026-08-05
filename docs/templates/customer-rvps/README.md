# customer-rvps — Trustee accept/reject on RVPS reference values

Ready-to-apply policy pair for the customer RVPS test: Trustee **accepts** (releases
KBS resources) when the SNP launch measurement in the evidence matches an RVPS
reference value, and **rejects** (withholds, 403) when it does not.

## The failure this template fixes

Symptom (trustee logs, on every `POST /kbs/v0/attest`, even for good evidence):

```
ERROR kbs::error: AttestationError(RcarAttestFailed { source: verify TEE evidence failed
Caused by:
    0: Failed to evaluate policy `default_cpu`
    1: not a valid rule path })
... "POST /kbs/v0/attest HTTP/1.1" 401
```

Root cause: a **KBS resource policy** (the submods/`allow` rego that evaluates
`input.submods[...]["ear.trustworthiness-vector"]`) was applied as the
**attestation policy** (`default_cpu.rego`). The two slots take different policy
shapes, run at different times, and see different inputs:

| Slot (ConfigMap / key) | Evaluated by | Input | Must emit |
| --- | --- | --- | --- |
| `attestation-policy` / `default_cpu.rego` | coco-as Ear token broker, at `/attest` | Verifier claims nested under the TEE name (`input.snp.measurement`, `input.snp.policy_debug_allowed`, …); only `init_data`/`report_data` are hoisted to top level (`input.init_data`). RVPS via the `query_reference_value("<name>")` rego extension | `trust_claims` (AR4SI tier numbers) |
| `resource-policy` / `policy.rego` | KBS policy engine, at resource GET | The EAR **token** claims (`input.submods[...]["ear.trustworthiness-vector"]`) | `allow` |

The Ear broker queries the trust-claim rules; the submods policy defines none of
them, so regorus fails with `not a valid rule path` and **every** attest 401s —
RVPS is never consulted. Note the log's earlier line `Verifier/endorsement check
passed` — evidence and the VCEK OfflineStore were fine; only the policy slot was
wrong.

Second gap this template closes: with the Ear broker, RVPS reference values only
matter if the attestation policy explicitly calls `query_reference_value("<name>")`
(a rego extension the broker registers, backed by RVPS; returns Null when the
value is absent — fail-closed). The base (permissive) policy doesn't call it, so
populating `rvps-reference-values` alone gates nothing.

### Symptom: token issued but everything at the fail-closed default

If the EAR debug log shows the appraisal Contraindicated with the vector stuck at
exactly the defaults (`executables 33, configuration 36, hardware 97`) even for
good evidence, the conditional rules never fired — almost always wrong claim
paths. The broker (`transform_claims` in trustee's `ear_token/broker.rs`) nests
verifier claims under the TEE name: use `input.snp.measurement`, NOT
`input.measurement` (flat paths are silently undefined in rego, so the rule body
just never matches). Only `init_data` and `report_data` sit at the top level. The
same all-defaults signature also appears when the claim paths are right but RVPS
has no `snp_launch_measurement` entry — check for the broker's "No reference value
found for the given id" warning to tell the two apart.

### Symptom: only `executables` stuck at 33 (hardware/configuration affirmed)

Claim paths are right; the RVPS lookup itself didn't match. In order:

1. **Is the entry there?** Look in the KBS log, just before the "Unsigned EAR
   Token" line, for `No reference value found for the given id:
   snp_launch_measurement` (WARN). If present, RVPS has no such entry: the
   `rvps-reference-values` ConfigMap is still the base `[]`, the Veritas output
   was never merged, or KBS was not restarted after merging (subPath mounts do
   not live-update — restart the deployment).
2. **Does the name and shape match?** Dump it:
   `oc -n trustee-operator-system get cm rvps-reference-values -o jsonpath='{.data.reference-values\.json}' | jq .`
   The entry must be named exactly `snp_launch_measurement` and its value must be
   a JSON **array** of measurement strings — rego's `in` never matches against a
   bare string. Also check the entry's `expiration` is in the future (expired
   reference values are dropped).
3. **Does the value match the evidence?** The expected measurement is in the AS
   DEBUG claims line of the failing attest (`"measurement":"..."` — 96 lowercase
   hex chars, SHA-384). If the stored array holds a different digest, Veritas was
   run against different bits than the node is booting (different OCP version,
   podvm image, or kernel cmdline) — re-run `make gen-rvps` on the target
   hardware with the versions actually deployed. If it holds the same digest in a
   different encoding (base64 / uppercase), normalize to lowercase hex.

A wrong-or-absent reference value with hardware/configuration affirmed is also
exactly what a correct REJECT looks like — the appraisal goes to Warning and the
resource policy withholds. Distinguish a broken happy path from a working reject
by whether the stored measurement was supposed to match.

## Files

- `attestation-policy.rvps.yaml` — appraisal policy: affirms `executables` (tier 3)
  only when `input.snp.measurement in query_reference_value("snp_launch_measurement")`
  (same rule as trustee's upstream `ear_default_policy_cpu.rego` SNP section);
  defaults fail closed (33/97/36). Also refuses debug-enabled guest policies.
- `resource-policy.ear-gate.yaml` — the customer's submods policy, in its correct
  slot: releases resources only when hardware/executables/configuration are all in
  the affirming range [2, 31].

## Apply

```sh
# 1. Populate RVPS from Veritas output (make gen-rvps → merge into the
#    rvps-reference-values ConfigMap; must contain snp_launch_measurement).
# 2. Apply both policies:
oc apply -f attestation-policy.rvps.yaml -f resource-policy.ear-gate.yaml
# 3. Restart KBS — the operator subPath-mounts these keys and subPath mounts do
#    not live-update:
oc -n trustee-operator-system rollout restart deployment/trustee-deployment
```

## Accept / reject test

- **Accept:** with RVPS populated from Veritas on this hardware, deploy the rung-kbs
  workload — the attestation-gate init container gets the secret and the pod runs.
- **Reject:** replace the `snp_launch_measurement` value in the
  `rvps-reference-values` ConfigMap with any wrong 96-hex-char digest (operator-side
  tamper — no guest changes needed), restart KBS, redeploy. `/attest` still returns
  a token (the vector is warning-tier, that is expected), but every resource GET is
  denied 403 and the pod fails closed. Because this resource policy gates **all**
  resources, a rejected guest also fails earlier CDH fetches (security policy,
  registry credentials), which makes the denial loud in pod events.
- An **empty** RVPS (`[]`, the gitops base) also rejects everything — fail-closed by
  design. The happy path requires populated reference values.

Restore the gitops base policies afterwards (or use `make negative-test
WHICH=rung-rvps`, which applies and reverts automatically).

## Testing without trusted reference values (TOFU)

The accept/reject *mechanism* can be proven even when the Veritas-derived values
are wrong or unavailable, by seeding RVPS with the measurement lifted from the
evidence itself (trust-on-first-use). This proves the full plumbing — RVPS →
appraisal policy → EAR vector → resource release/denial — but says nothing about
provenance; production still needs Veritas-derived values.

1. Take the live measurement from the AS DEBUG claims line of any attest
   (`"measurement":"…"` — 96 lowercase hex chars).
2. Seed it into the `rvps-reference-values` ConfigMap. For trustee v0.17/v0.18
   (`file_path`-style LocalJson storage) `reference-values.json` is a JSON array
   of reference-value objects:

   ```json
   [
     {
       "version": "0.1.0",
       "name": "snp_launch_measurement",
       "expiration": "2027-01-01T00:00:00Z",
       "value": ["<measurement-hex-from-evidence>"]
     }
   ]
   ```

   `value` MUST be an array; `expiration` MUST be future, format exactly
   `%Y-%m-%dT%H:%M:%SZ`.
3. Restart the KBS deployment, redeploy the workload → **accept** (vector shows
   `executables 3`, secret released).
4. Flip one hex digit of the stored value, restart KBS, redeploy → **reject**
   (`executables 33`, token still issued, resource GET 403, pod fails closed).
   Restore to flip back. Entirely operator-side — no guest changes.

### Version trap: trustee ≥ v0.19 silently ignores `file_path`

From trustee v0.19 the RVPS LocalJson storage moved to a key-value backend
configured by `file_dir_path` (default
`/opt/confidential-containers/storage/local_json`, namespace file
`reference_value`, values base64url-encoded). The old
`[attestation_service.rvps_config.storage] file_path = …` key is accepted but
IGNORED (no deny_unknown_fields), so the mounted ConfigMap is never read and
every query warns `No reference value found` no matter what you seed. Detect it:

```sh
oc -n trustee-operator-system exec deploy/trustee-deployment -- \
  ls /opt/confidential-containers/storage/local_json/ 2>/dev/null
```

If `reference_value` exists there, the build is ≥ v0.19: point the storage
config at the mount with `file_dir_path` and provide the file in the new format
(key-to-base64url map named after the namespace), or align the trustee version
with the v0.17/18-style config.
