# GitOps tree

Kustomize is the common substrate. The rig drives it with `oc apply -k` (see `../Makefile`);
the customer env points **mirrored ArgoCD** at the same tree.

## Overlay matrix — `{sno, customer} × {workers, trustee}`

| Overlay | Composes | Differs by |
|---------|----------|------------|
| `sno-workers` | operators + kataconfig + workloads | single-node, co-located, insecure-HTTP-friendly |
| `sno-trustee` | trustee | secondary rig Trustee cluster |
| `customer-workers` | operators + kataconfig + workloads | multi-node selectors, replicas, mirrored images |
| `customer-trustee` | trustee | separate Trustee cluster, external KBS URL, OfflineStore VCEK |

## What is portable vs hardware-bound

- **Portable** (prove on rig, reuse): manifests, operator subscriptions + order
  (NFD → cert-manager → OSC → Trustee), KBS ConfigMaps, Rego policies, initdata *structure*.
- **Hardware-bound** (regenerate on customer metal): VCEK certs (their HWIDs), RVPS reference
  values (their CPU+firmware), TLS certs + Trustee URL, initdata *measured bytes*.

Bases are intentionally empty skeletons — populate from the onboarding guide Steps 3–6 as each
rung is replay-verified on the rig.
