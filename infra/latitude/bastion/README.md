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
cp terraform.tfvars.example terraform.tfvars   # FILL: plan (cheap metal SKU), site == node's site
export LATITUDESH_AUTH_TOKEN=...
export TF_VAR_mirror_init_password=...          # do NOT commit the mirror admin password
terraform init
terraform apply                                  # <-- spends money; approve explicitly
terraform output mirror_endpoint                 # -> MIRROR_REGISTRY host:port for `make mirror`
```

Watch the bootstrap: `ssh ubuntu@<bastion-ip>` then `tail -f /var/log/mirror-bootstrap.log`.
Ready when `<mirror_root>/MIRROR_READY` exists. Carry `<mirror_root>/ca/rootCA.pem` into the
install kit (`install-config` `additionalTrustBundle`).

## The egress firewall is a `# VERIFY`, not a guarantee

Latitude firewalls are deny-by-default, but whether a rule constrains a server's **egress**
(vs inbound only) is **undocumented**. So:

- The firewall **ruleset is defined here**, but the node only **attaches** it when you set
  `-var enforce_latitude_firewall=true` in `../` (default **false**).
- On first provision, run the egress probe (runbook Phase 1): from the node, try to reach a
  public address that is *not* the bastion. If it succeeds with the firewall attached, Latitude
  is inbound-only — **use the host-nftables default-deny-egress fallback** in the runbook
  instead. Do not claim the air gap is enforced until the probe confirms it.

## Tear down (only at the end of the engagement)

```bash
terraform destroy   # loses the mirror cache — only when the whole spike is done
```
