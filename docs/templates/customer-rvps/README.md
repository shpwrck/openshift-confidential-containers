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
