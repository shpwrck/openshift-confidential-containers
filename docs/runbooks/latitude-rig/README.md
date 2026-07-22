---
leave-behind: v1
state-scope: latitude-rig
status: current
---

# Latitude rig — live infrastructure state (leave-behind)

The disposable CoCo test rig on Latitude.sh, rebuilt **from zero** starting 2026-07-22 (the
previous engagement's bastion/node no longer exist). This artifact records what is live, how
to reach it, and how to re-drive it; update it in place as the rig evolves — one artifact for
this scope, never fork per session.

## Operability

### State and access
- **Latitude project:** `proj_nPRbaj96G5koM` ("Test"), site **NYC**, hourly billing.
- **Bastion** (persistent mirror/air-gap host): `coco-bastion`, plan `m4-metal-small`
  ($1.11/h), Rocky 10. `terraform apply` launched 2026-07-22 from
  `infra/latitude/bastion/` (state: local `terraform.tfstate` in that dir, on this
  workstation). Cloud-init self-configures VLAN L3, dnsmasq, chrony, and the Quay
  mirror-registry on first boot.
- **SNP node** (disposable): NOT yet applied. Will be `m4-metal-medium` (EPYC 9124 Genoa,
  $1.58/h) from `infra/latitude/` once the mirror push is under way.
- **SSH:** `rocky@<bastion-public-ip>` (`terraform output` in the bastion dir). The Latitude
  key `coco-rig` (`ssh_PVwea4BBRNB9O`) corresponds to the **local private key
  `~/.ssh/id_ed25519.wsl`** on this workstation — pass `-i`/`--private-key` explicitly.
- **Credential locations (never values):** Latitude API token = `LATITUDESH_AUTH_TOKEN` env
  var (user-exported; session copy in the Claude scratchpad `latitude-env.sh`, mode 0600,
  ephemeral). RH pull secret = `/home/jskrzype/pull-secret.json` (workstation), staged to
  `~/pull-secret.json` on the bastion for Phase A. Mirror admin password = generated on the
  bastion at `/opt/mirror/mirror-admin-password` (root-only, never in TF state). Inbound
  admin CIDR pinned to `67.241.169.121/32`.

### Template map
- `infra/latitude/bastion/terraform.tfvars.example -> infra/latitude/bastion/terraform.tfvars` (gitignored; filled 2026-07-22: project/site/plan/ssh-key/admin_cidr above)
- `infra/latitude/terraform.tfvars.example -> infra/latitude/terraform.tfvars` (gitignored; filled 2026-07-22: node plan `m4-metal-medium`, `rocky-10`)
- `infra/latitude/bastion/cloud-init/mirror-registry.yaml -> Latitude user_data (bastion first-boot)` (rendered by Terraform template vars)
- `ansible/group_vars/all.yml -> every Phase A–C task var` (runtime env `LATITUDESH_AUTH_TOKEN` / `ARTIFACTORY_REGISTRY` looked up, never committed)

### Re-run
```bash
ENV=/tmp/claude-*/*/*/scratchpad/latitude-env.sh   # or: export LATITUDESH_AUTH_TOKEN=...
. $ENV
# 1. Bastion (idempotent; safe to re-apply):
terraform -chdir=infra/latitude/bastion init -input=false
terraform -chdir=infra/latitude/bastion apply
# 2. Stage pull secret + Phase A (egress, tools, ~1-2h mirror push, dns/ntp):
scp -i ~/.ssh/id_ed25519.wsl /home/jskrzype/pull-secret.json rocky@<bastion-ip>:pull-secret.json
cd ansible && ansible-playbook playbooks/site.yml --tags bastion-prep \
  --private-key ~/.ssh/id_ed25519.wsl -e bastion_ansible_host=<bastion-ip>
# 3. Node + install (STOPS at the SEV-SNP BIOS pause — Latitude IPMI, hands-on):
terraform -chdir=infra/latitude init -input=false && terraform -chdir=infra/latitude apply
cd ansible && ansible-playbook playbooks/site.yml --tags install \
  --private-key ~/.ssh/id_ed25519.wsl -e bastion_ansible_host=<ip> \
  -e bastion_public_ipv4_override=<ip> -e vlan_vid_override=<tf output> \
  -e node_server_id=<tf output> -e boot_artifacts_token=$(openssl rand -hex 16)
# 4. After node boot: close the secret-bearing boot endpoint:
ansible-playbook playbooks/site.yml --tags pxe-stop ...
```
Or the wrapper for 2–4: `make bringup-sno-airgapped ARGS="--apply-tf -e ..."` (ansible/up.sh).

### Verify and recover
- **Verify bastion:** `terraform -chdir=infra/latitude/bastion output`;
  `ssh -i ~/.ssh/id_ed25519.wsl rocky@<ip> 'cloud-init status --wait; sudo podman ps'`;
  mirror health `curl -k https://<ip>:8443/health/instance` (name-correct via
  `mirror.rig.local` once dnsmasq/hosts resolve). Provision status:
  `curl -s -H "Authorization: Bearer $LATITUDESH_AUTH_TOKEN" https://api.latitude.sh/servers?filter%5Bproject%5D=proj_nPRbaj96G5koM`.
- **Recover node:** disposable — `terraform -chdir=infra/latitude destroy` + re-apply freely.
  **Every re-provision resets the BIOS**: the SEV-SNP recipe must be re-applied via IPMI.
- **Recover bastion:** destroying it loses the ~1–2 h mirror cache — destroy only at
  engagement end (`terraform -chdir=infra/latitude/bastion destroy`). Bastion outlives node
  re-provisions on purpose; the node rejoins the same mirror.
- **Cost guard:** ~$2.69/h while both run. Tear the node down between work sessions.

## Decision log

### Decisions
- **From-zero rebuild (2026-07-22):** prior rig is gone; nothing to resume.
- **Spend approved by the user 2026-07-22:** bastion `m4-metal-small` + node
  `m4-metal-medium` in NYC, hourly (~$2.69/h combined) — the SKU pair the repo's
  group_vars/cloud-init are already tuned for (Genoa `enp195s0f1`, no-bond0 NIC detect).
- **No Artifactory/JCR on the rig (user decision):** existing mirror-registry automation
  only; the customer-Artifactory bundle is exercised via the `ARTIFACTORY_REGISTRY` seam
  (#26). JCR researched and rejected for now.
- **Purpose:** live-prove `docs/runbooks/debug-surface.md` (draft PR #60 — the user's merge
  gate: nothing merges until proven on this rig) by capturing a clean-run signature, then
  deliberately breaking each triage branch, negative-test style.

### How to drive it
Phase order and stop-gates live in `ansible/up.sh` (printed sequence) and
`ansible/playbooks/site.yml` (tags: `bastion-prep`, `bios`, `discover`, `install`,
`pxe-stop`). The one hands-on step is the SEV-SNP BIOS via Latitude IPMI (recipe printed by
the playbook pause; also `docs/notes/latitude-snp-bringup.md`). After bring-up, rungs and
negative tests run via the Makefile (`verify-snp-host`, `apply-*`, `negative-test`,
`repro-loop`). Session driving this now: bastion apply in a background task; next actions =
stage pull secret → Phase A → node apply.
