# Latitude.sh rig — provision one SNP-capable bare-metal node

Reproducible up/down for the disposable SEV-SNP verification node. **Destroy after each spike**
(hourly billing). Provisioning spends money — `terraform apply` is gated on your approval.

## Prereqs
- Latitude account + API token → `export LATITUDESH_AUTH_TOKEN=...`
- `terraform` (or `tofu`), `ssh`. Optional: the `lsh` CLI to query plans/sites.
- An SSH key (existing Latitude key id, or `create_ssh_key=true`).

## Pick a plan + site (Genoa, hourly)
```bash
lsh plans list        # find a 4th-gen EPYC (Genoa 9004) SKU + a site with stock
lsh projects list     # get your proj_... id
```
Fill `terraform.tfvars` (copy from `terraform.tfvars.example`).

## Provision
```bash
cd infra/latitude
terraform init
terraform plan        # review
terraform apply       # <-- spends money; approve explicitly
terraform output ssh_hint
```

## Pre-flight (confirmed before spend, 2026-06-25)
- **IPMI/BIOS access: yes** — Latitude provides browser IPMI + serial-console-over-SSH on all
  sites (<https://docs.latitude.sh/docs/ipmi>), so we can reach AMD CBS to enable SNP.
- **Billing: no setup fee, no documented hourly minimum** for bare metal; hourly = pay-for-use.
- Residual unknown the spike resolves: is the AMD CBS SNP submenu reachable (not vendor-locked)
  on this node — visible within minutes on the IPMI console.

## Verify SEV-SNP host
1. SSH in (root@<primary_ipv4>; if refused, use the **IPMI serial console** as fallback).
2. `scp ../../scripts/host-snp-check.sh <ip>: && ssh <ip> bash host-snp-check.sh`.
   The script **discriminates** kernel-incapable vs BIOS-off vs provider-veto — a FAIL is NOT
   automatically a provider veto; follow its RESULT guidance.
3. If it points at BIOS: IPMI console → reboot → AMD CBS: **SEV-SNP Support** + **SMEE** on,
   **SEV-ES ASID Space Limit** > 0, **RMP Table** on, **Memory Interleaving** off (Error 0x3).
   Re-run. A green result proves silicon+provider — NOT the RHCOS kernel (that's the later phase).

## Tear down (do this when done — saves money)
```bash
terraform destroy
```
