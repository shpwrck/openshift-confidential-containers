# Latitude.sh bastion — persistent air-gap mirror host

The **long-lived** half of the rig. Stands up the disconnected-install support infrastructure
once, so the disposable SNP node (`../`) can be cycled underneath it freely:

- a **private virtual network** (VLAN) the SNP node joins,
- a **bastion** bare-metal host running Red Hat **`mirror-registry`** (quay),
- the **egress-lockdown firewall** the SNP node attaches to (see the VERIFY caveat below).

## Why separate from the node module

Mirroring is the **~1–2 h bottleneck** and it is **cacheable**. This module keeps the mirror
workspace on the bastion's own disk (`mirror_root`, default `/opt/mirror`), so:

> **Apply the bastion once → re-provision the SNP node as many times as you like → pay the
> mirror cost once.** `terraform destroy` in `../` removes only the node; the mirror survives.

Different state, different lifecycle. **Apply this module first** — the node module reads its
outputs (`virtual_network_id`, `firewall_id`) via `terraform_remote_state`.

## Provision

```bash
cd infra/latitude/bastion
cp terraform.tfvars.example terraform.tfvars   # FILL: plan (cheap metal SKU), site == node's site, admin_cidr
export LATITUDESH_AUTH_TOKEN=...
terraform init
terraform apply                                  # <-- spends money; approve explicitly
terraform output mirror_endpoint                 # -> MIRROR_REGISTRY host:port for `make mirror`
```

Watch the bootstrap: `ssh ubuntu@<bastion-ip>` then `tail -f /var/log/mirror-bootstrap.log`.
Ready when `<mirror_root>/MIRROR_READY` exists. Then grab the two things the install kit needs:

```bash
ssh ubuntu@<bastion-ip> 'sudo cat /opt/mirror/mirror-admin-password'   # registry admin pw (generated on-box)
ssh ubuntu@<bastion-ip> 'sudo cat /opt/mirror/ca/rootCA.pem'           # -> install-config additionalTrustBundle
```

The admin **password is generated on the bastion** (0600 root-only) — it is deliberately never
in Terraform state, the Latitude user-data store, or this repo.

## Two firewalls, two layers — don't confuse them

- **Inbound** to the node: `latitudesh_firewall` here (SSH/API/ingress from `admin_cidr` only,
  deny the rest). Attach via `-var enforce_latitude_firewall=true` in `../` (off by default so a
  wrong `admin_cidr` can't lock you out). `admin_cidr` is **required** — no `0.0.0.0/0` default.
- **Egress** lockdown (the air gap): **host-side nftables**, NOT a Latitude firewall — its egress
  direction is undocumented, so we don't ship a false control. Runbook Phase 1 has the
  default-deny-output-except-bastion snippet **and** the probe that proves public egress is
  actually blocked. Do not claim the air gap is enforced until that probe is green.

## Tear down (only at the end of the engagement)

```bash
terraform destroy   # loses the mirror cache — only when the whole spike is done
```
