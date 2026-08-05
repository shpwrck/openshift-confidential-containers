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
| `attestation-policy` / `default_cpu.rego` | coco-as Ear token broker, at `/attest` | Flat verifier claims (`input.measurement`, `input.init_data`, `input.policy_debug_allowed`, …) + RVPS as `data.reference.<name>` | `trust_claims` (AR4SI tier numbers) |
| `resource-policy` / `policy.rego` | KBS policy engine, at resource GET | The EAR **token** claims (`input.submods[...]["ear.trustworthiness-vector"]`) | `allow` |

The Ear broker queries the trust-claim rules; the submods policy defines none of
them, so regorus fails with `not a valid rule path` and **every** attest 401s —
RVPS is never consulted. Note the log's earlier line `Verifier/endorsement check
passed` — evidence and the VCEK OfflineStore were fine; only the policy slot was
wrong.

Second gap this template closes: with the Ear broker, RVPS reference values only
matter if the attestation policy explicitly reads `data.reference.<name>`. The
base (permissive) policy doesn't, so populating `rvps-reference-values` alone
gates nothing.

## Files

- `attestation-policy.rvps.yaml` — appraisal policy: affirms `executables` (tier 3)
  only when `input.measurement in data.reference.snp_launch_measurement`; defaults
  fail closed (33/97/36). Also refuses debug-enabled guest policies.
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
