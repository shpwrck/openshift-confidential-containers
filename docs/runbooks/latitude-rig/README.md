---
leave-behind: v1
state-scope: latitude-rig
status: current
---

# Latitude rig — live infrastructure state (leave-behind)

The disposable CoCo test rig on Latitude.sh. **Cycle 2026-07-28 is IN PROGRESS**: bastion and node
are both applied and Phase A is complete; the rig is **stopped at the hands-on SEV-SNP BIOS step**,
which the rung-0 gate confirms is required on this unit. The previous cycle (2026-07-22) was
destroyed the same day; its record is preserved in *Decision log → History*.

This cycle is a true from-zero rebuild: the destroyed bastion took the mirror cache, so the
oc-mirror push re-runs under the OSC 1.12.x / Trustee 1.1.x pins from PR #67, and the VCEK
OfflineStore must be re-collected for the new node's chip.

## Operability

### State and access
- **Latitude project:** `proj_nPRbaj96G5koM` ("Test"), site **NYC**, hourly billing.
  **Cost: ~$1.11/h bastion alone, ~$2.69/h once the node is up.** Tear the node down between
  work sessions; destroy the bastion only at engagement end (it holds the mirror cache).
- **Bastion** (persistent mirror/air-gap host): `coco-bastion` = **`sv_6B9VaL4lEa7vr`**, public
  **64.34.90.7**, plan `m4-metal-small`, **rocky-10**, bastion VLAN IP 192.168.66.10, mirror
  endpoint `mirror.rig.local:8443`. Applied 2026-07-28 from `infra/latitude/bastion/`
  (5 resources: server, VLAN, VLAN assignment, firewall, user_data). Note the API reissued the
  **same server id and public IP as the destroyed 2026-07-22 bastion** — do not read that as the
  old host surviving; it is a fresh provision with a fresh disk and no mirror cache.
- **SNP node** (disposable): `coco-snp-rig` = **`sv_ZWr75ZP9v0A91`**, public **185.209.179.93**,
  plan `m4-metal-medium` (EPYC 9124 Genoa), **rocky-10**, kernel 6.12, applied 2026-07-28 (14m10s).
  VLAN assignment `vnasg_mMGO022xP0Aln`. IPMI credentials are minted on demand into the
  **gitignored** `infra/latitude/IPMI-ACCESS.md` (never committed; token expires ~12h) via
  `POST /servers/<id>/remote_access`.
  **Rung-0 state: NOT live — SEV-SNP BIOS is OFF on this unit** (`ccp … SEV: memory encryption
  not enabled by BIOS`, `sev_snp=N`, no `/dev/sev`; kernel/CONFIG/module checks all PASS).
  Awaiting the hands-on BIOS step. Note this settles the "does BIOS persist per unit?" question
  the only way that is safe: **by measuring, not assuming** — this draw came up reset.
- **SSH:** `rocky@64.34.90.7`. The Latitude key `coco-rig` (`ssh_PVwea4BBRNB9O`) corresponds to
  the local private key **`~/.ssh/id_ed25519`** — verified 2026-07-28 by comparing the registered
  public key material against `~/.ssh/id_ed25519.pub` via `GET /ssh_keys`. (A `~/.ssh/id_ed25519.wsl`
  copy also exists on this workstation; both are the same key. Earlier revisions of this file named
  `.wsl` as authoritative — it is not, it is a per-workstation alias.)
- **Credential locations (never values):** Latitude API token = **`LATITUDESH_AUTH_TOKEN` in the
  gitignored repo-root `.env`** (`set -a; . ./.env; set +a`). Both paths named by earlier revisions
  are DEAD — the Claude scratchpad `latitude-env.sh` is ephemeral and gone, and
  `~/.claude.json → projects[repo].mcpServers.latitudesh` is now an empty list. Regenerate at
  Latitude dashboard → Settings → API Keys; the token is validated by
  `curl -H "Authorization: Bearer $LATITUDESH_AUTH_TOKEN" https://api.latitude.sh/projects`.
  RH pull secret = **`<repo>/pull-secret.json`** (earlier revisions said `/home/jskrzype/...`, a
  typo — that path does not exist). Mirror admin password = generated on the bastion at
  `/opt/mirror/mirror-admin-password` (root-only, never in TF state).
- **Inbound is OPEN by design.** `bastion/terraform.tfvars` sets `admin_cidr = "0.0.0.0/0"`, and
  `enforce_latitude_firewall` defaults false so `main.tf:58-62` is `count = 0` and the Latitude
  firewall is never attached. Host-side nftables (`bastion_egress`, `99-airgap-egress`) is the real
  control. Earlier revisions claimed a pinned `/32`; that was not in effect — do not "restore" it
  without checking you are not locking yourself out.

### Template map
- `infra/latitude/bastion/terraform.tfvars.example -> infra/latitude/bastion/terraform.tfvars` (gitignored; filled: project/site/plan `m4-metal-small`/`ssh_PVwea4BBRNB9O`/`admin_cidr`/`vlan_parent_interface = "eno2"`)
- `infra/latitude/terraform.tfvars.example -> infra/latitude/terraform.tfvars` (gitignored; filled 2026-07-28: `m4-metal-medium`, NYC, **`operating_system = "rocky-10"`**, `ipxe_url = ""`. The `.example` is NOT copy-ready — it lacks `ipxe_url`/`bastion_state_path`.)
- `infra/latitude/bastion/cloud-init/mirror-registry.yaml -> Latitude user_data (bastion first-boot)` (rendered by Terraform template vars; stamps `/opt/mirror/MIRROR_READY` or `MIRROR_FAILED` at the END of its chain)
- `ansible/group_vars/all.yml -> every Phase A–C task var` (runtime env `LATITUDESH_AUTH_TOKEN` / `ARTIFACTORY_REGISTRY` looked up, never committed)

### Re-run
```bash
cd <repo>; set -a; . ./.env; set +a          # LATITUDESH_AUTH_TOKEN
KEY=~/.ssh/id_ed25519                         # private half of coco-rig (ssh_PVwea4BBRNB9O)

# 1. Bastion (idempotent; safe to re-apply):
terraform -chdir=infra/latitude/bastion init -input=false
terraform -chdir=infra/latitude/bastion apply
BAS=$(terraform -chdir=infra/latitude/bastion output -raw bastion_public_ipv4)

# 2. Stage the pull secret (Phase A needs it on the bastion):
scp -i $KEY pull-secret.json rocky@$BAS:pull-secret.json

# 3. Phase A (egress, tools, ~15min+ mirror push under the #67 pins, dns/ntp).
#    Phase A now WAITS for cloud-init's MIRROR_READY itself (#71) — no manual sleep needed.
cd ansible && ansible-playbook playbooks/site.yml --tags bastion-prep \
  --private-key $KEY -e bastion_ansible_host=$BAS

# 4. Node. tfvars provisions rocky-10 so the node is SSH-reachable BEFORE netboot; ansible
#    install_drive then reinstalls it to ipxe with a freshly rendered URL.
terraform -chdir=infra/latitude init -input=false && terraform -chdir=infra/latitude apply
NODE_ID=$(terraform -chdir=infra/latitude output -raw server_id)
VID=$(terraform -chdir=infra/latitude/bastion output -raw virtual_network_vid)

# 5. HUMAN GATE — SEV-SNP BIOS via Latitude IPMI/KVM, then PROVE it over SSH:
ssh -i $KEY rocky@<node-ip> 'sudo bash -s' < scripts/host-snp-check.sh   # expect all PASS

# 6. Phase B+C. RUN IN A REAL TTY: the BIOS gate now asserts a typed SNP-SET token (#72).
ansible-playbook playbooks/site.yml --tags install --private-key $KEY \
  -e bastion_ansible_host=$BAS -e bastion_public_ipv4_override=$BAS \
  -e vlan_vid_override=$VID -e node_server_id=$NODE_ID \
  -e boot_artifacts_token=$(openssl rand -hex 16)      # fresh per cycle; never reuse

# 7. Close the secret-bearing boot endpoint once the node has booted:
ansible-playbook playbooks/site.yml --tags pxe-stop --private-key $KEY -e bastion_ansible_host=$BAS
```
**Re-derive every cycle, never reuse:** bastion + node public IPs, VLAN id/vid, node server id,
`boot_artifacts_token`, `ipxe_url`, mirror admin password, VCEK OfflineStore (new CHIP_ID).
**Reusable:** project id, site NYC, the two plans, ssh key id `ssh_PVwea4BBRNB9O`,
`vlan_parent_interface = "eno2"`.

### Verify and recover
- **Verify bastion:** `terraform -chdir=infra/latitude/bastion output`;
  `ssh -i ~/.ssh/id_ed25519 rocky@$BAS 'cloud-init status --wait; ls /opt/mirror/MIRROR_READY; sudo podman ps'`;
  mirror health `curl -k https://$BAS:8443/health/instance`. Provision status via
  `GET https://api.latitude.sh/servers?filter[project]=proj_nPRbaj96G5koM`.
- **cloud-init does NOT re-run.** If `/opt/mirror/MIRROR_FAILED` is present, read
  `/var/log/mirror-bootstrap.log` and re-run `/usr/local/bin/bootstrap-mirror.sh` by hand before
  retrying Phase A. Phase A now fails closed on this rather than half-running (#71).
- **Recover node:** disposable — `terraform -chdir=infra/latitude destroy` + re-apply freely.
  Re-provisioning may reset the BIOS; **never assume either way — settle it with the rung-0
  check in Re-run step 5**, which is why the node is provisioned SSH-reachable.
- **Recover bastion:** destroying it loses the mirror cache. Destroy only at engagement end.
- **Teardown (stop billing):** `terraform -chdir=infra/latitude destroy` then
  `terraform -chdir=infra/latitude/bastion destroy`; confirm with the servers API returning 0.

## Decision log

### Decisions
- **From-zero rebuild (2026-07-28)** on user request; account was at 0 servers, both tfstates
  empty. Nothing to import or resume.
- **Fix the two pre-flight blockers BEFORE spending** (user's call, PR #77):
  1. **#71 — Phase A raced bastion cloud-init.** Terraform returns at server-`on`, but cloud-init
     writes the mirror CA + admin password at the very END of its chain, one line before stamping
     `MIRROR_READY`; `mirror_tools` consumes both, and nothing anywhere waited on that marker.
     Never bit before because every prior cycle reused an already-bootstrapped bastion.
  2. **#72 — the SEV-SNP BIOS stop-gate silently no-opped.** A bare `ansible.builtin.pause` warns
     and falls through without a TTY, so the hands-off path skipped the one hands-on hardware step
     and netbooted with SNP off — producing a healthy-looking, non-confidential cluster, with the
     first evidence a rung-0 failure hours later. Now asserts a typed `SNP-SET` token.
- **Node provisioned as `rocky-10`, not `ipxe` (2026-07-28).** The committed `ipxe_url` pointed at
  the destroyed 2026-07-22 bastion with a dead token. Since `install_drive` re-triggers a Latitude
  reinstall with a freshly rendered URL, the tfvars value only governs the FIRST boot — so booting
  a real OS costs nothing and buys an SSH-reachable node, which is what makes the BIOS step
  *verifiable* (`host-snp-check.sh`) rather than merely acknowledged.
- **Remaining pre-flight findings deliberately NOT fixed before provisioning** (they bite later
  phases): #73 three hand-staged files nothing generates (`coco-rig.pub` aborts Phase C,
  `kbs.pub` aborts Phase 5), #74 oc-mirror cluster-resources never applied (stalls
  `install-coco-operators` the full 1800s), #75 GitOps apply-ordering, #76 stale runbook facts
  (this rewrite addresses them).
- **Superseded by evidence:** PRs #62 (#61 mirror_push) and #64 (#63 clusterversion jsonpath)
  **merged 2026-07-22 20:08–20:09 UTC**. `main` is NOT broken; earlier revisions of this file told
  the next operator to run from the fix branches — ignore that.

### History — cycle 2026-07-22 (destroyed)
Rebuilt from zero and destroyed the same day (~7 h live, ≈$15–20). Proved **rung-a end-to-end**
(happy + air-gap VCEK-swap denial PASS) at 21:43 UTC: OfflineStore SNP attest (`tee=Snp`, KDS
nftables-blocked) → EAR token verified against the persistent EC signer → `credential` /
`security-policy` / `registry-configuration` released 200 → in-guest pull from
`mirror.rig.local:8443`. Left behind PR #60 (debug guide) and merged fixes #62/#64/#67.
**Rig deltas never back-ported** — still true, still pending: the catalog delivered
trustee-operator **v1.2.1** and the committed v1.1-era wiring does NOT work against it (#65);
KbsConfig policy ConfigMap fields must be removed (the v1.2.1 migration sweeper deletes any
referenced policy CM → deadlock); `kbs-config` needs 1.2-format toml with the `.v1.1` backup CM
kept; kata `create_container_timeout=600` + kubelet `runtimeRequestTimeout=20m` (#6/#73-adjacent);
KataConfig `logLevel: debug` is MCO-plumbed on this build (a patch costs a reboot).
**⚠️ Air gap is NOT reboot-stable (#66):** after ANY reboot verify `nft list table inet airgap`
and that `curl quay.io` fails — the unit reporting success is not proof.

### How to drive it
Phase order and stop-gates live in `ansible/up.sh` (printed sequence) and
`ansible/playbooks/site.yml` (tags: `bastion-prep`, `bios`, `discover`, `install`, `pxe-stop`).
Phase A self-gates on the mirror bootstrap; the BIOS gate fails closed unless acknowledged with
`SNP-SET` (or deliberately bypassed with `-e skip_bios_pause=true`, which you should only do once
`host-snp-check.sh` is green on that node). The one hands-on step is the SEV-SNP BIOS via Latitude
IPMI/KVM — recipe printed by the playbook pause and in `docs/notes/latitude-snp-bringup.md`; the
gotcha is **SEV-SNP Support = Enabled, not Auto** (Auto silently leaves it off and produces the
misleading "IOMMU SNP feature not enabled" message — do not chase IOMMU). After bring-up, rungs
and negative tests run from the Makefile (`verify-snp-host`, `apply-*`, `negative-test`,
`repro-loop`). Current position in the sequence: **bastion applied + Phase A COMPLETE (52 ok / 27 changed /
0 failed; mirror healthy, `OCMIRROR_DONE` set, cluster-resources emitted); node applied and
SSH-reachable; STOPPED at the hands-on SEV-SNP BIOS step, which rung-0 confirms is required on
this unit.** Next after BIOS: re-run `host-snp-check.sh` (must be all PASS), then Phase B+C in a
real TTY, then `--tags pxe-stop`. Remember #74 — apply
`/opt/mirror/ocm-workspace/working-dir/cluster-resources/` by hand before
`make install-coco-operators`, or it stalls the full 1800s on a missing CatalogSource.
