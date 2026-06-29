# OpenShift Confidential Containers

Stand up **OpenShift Confidential Containers (CoCo)** with AMD SEV-SNP on bare metal,
prove each capability on a disposable test rig, then apply the proven configuration to the
target air-gapped multi-node cluster.

## Stack

| Layer | Choice |
|-------|--------|
| TEE | **AMD SEV-SNP** first; Intel TDX added later as an additive overlay (⚠️ see air-gap caveat) |
| Path | **Bare-metal Kata host** (the worker's RHCOS kernel IS the SNP host) — not peer-pods |
| Platform | OpenShift, OSC **1.12**, Red Hat build of Trustee **1.1**, OCP ≥ 4.19.28 / 4.20.18 |
| Attestation (air-gap) | Trustee-side **OfflineStore** VCEK cache (`kbsLocalCertCacheSpec`) — see [design doc](docs/design/engagement-design.md) |
| GitOps | Kustomize substrate; `oc apply -k` + Makefile on the rig; ArgoCD (mirrored) in the production env |

## Visual overview

See [`docs/architecture.md`](docs/architecture.md) for component diagrams, the attestation sequence, and the step-by-step flow from bastion preparation through negative tests and production promotion.

## Environments

- **Test rig** — Single Node OpenShift (SNO) on one **Latitude.sh hourly** bare-metal node,
  plus a secondary Trustee cluster. Disposable; spun up, proven, destroyed. Simulated air-gap
  (bastion/mirror host + egress-firewalled node).
- **Production** — full **multi-node** bare metal, **air-gapped**, separate Trustee cluster.

## Capability rungs (prove on rig → apply to production)

- **a** — KBS secret-resource release (attestation gates a credential)
- **b** — encrypted container image (wrong measurement → pod won't start)
- **c** — signed image (`image_security_policy`)

Each rung is "done" only when (1) reproduced from written steps on a fresh node and (2) its
**negative test** (the denial) passes. See [`docs/design/engagement-design.md`](docs/design/engagement-design.md).

## Layout

```
docs/install-guide.md  fully MANUAL, provider-neutral bring-up (no Terraform/Ansible)
docs/runbooks/         phase checklists for the automated path + failure modes
docs/design/           design notes + pre-deployment scoping list
docs/notes/            hardware bring-up + air-gap guest-pull reference notes
infra/                 Terraform (node, bastion, VLAN, firewall, netboot)
ansible/               bastion config + OpenShift install automation (`make up`)
gitops/                Kustomize base/ + overlays {sno,customer} × {workers,trustee}
scripts/               rung-0 SNP-host gate, VCEK collection, Veritas RVPS
Makefile               rig driver (verify gates, apply rungs)
```

## Start here

- **By hand (any provider):** follow [`docs/install-guide.md`](docs/install-guide.md) — the
  full manual procedure, no Terraform/Ansible.
- **Automated (Latitude.sh):** use the Terraform + Ansible + `Makefile` path:

```bash
make help                  # list targets
make verify-snp-host NODE=<node>   # rung-0 gate: prove SEV-SNP host before any GitOps
```
