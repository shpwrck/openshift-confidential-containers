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
- **Bastion** (persistent mirror/air-gap host): `coco-bastion` = `sv_6B9VaL4lEa7vr`,
  public **64.34.90.7**, VLAN `vlan_jmlR571Zz0WgY` vid **2162** (bastion 192.168.66.10),
  plan `m4-metal-small` ($1.11/h), Rocky 10. Applied 2026-07-22 from
  `infra/latitude/bastion/` (state: local `terraform.tfstate` in that dir, on this
  workstation). Mirror-registry (Quay) up; `MIRROR_READY` confirmed; oc-mirror push in
  progress (Phase A re-run after the #61 fix).
- **SNP node** (disposable): `sv_BoQ45AJw3aMYA`, public **69.67.151.235**, VLAN
  **192.168.66.11**, plan `m4-metal-medium` (EPYC 9124 Genoa, $1.58/h). SEV-SNP BIOS set
  by hand 2026-07-22 (rung-0 gate: all 8 checks PASS, `/dev/sev` live). **SNO 4.20.18
  INSTALLED** (agent-based, netboot from bastion): node Ready, clusterversion Available,
  baseline gate PASS, mirror cluster-resources applied, boot endpoint closed
  (`pxe-stop`), `99-airgap-egress` MachineConfig applied (node egress to public internet
  dropped — verify after each reboot). Cluster access: on the bastion,
  `KUBECONFIG=/opt/install/cluster-assets/auth/kubeconfig`; node ssh `core@192.168.66.11`
  via bastion jump (same key).
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

### Proof state
**rung-a PROVEN on this rig 2026-07-22 21:43 UTC** — `rung-a-secret 1/1 Running`,
`runtimeClassName: kata-cc` (handler kata-snp): OfflineStore SNP attest (`attest 200`,
`tee=Snp`, KDS nftables-blocked) → EAR token verified against the persistent EC signer →
`credential`/`security-policy`/`registry-configuration` all released 200 → in-guest pull
from `mirror.rig.local:8443` (`oci-client/0.15.0`, manifests+blobs 200). En route, the
ephemeral-signer failure (#65 break 3) was reproduced live: attest 200 + resource 401 +
in-guest `ttrpc request error` — the customer-symptom signature, now with a known fix.

### Rig deltas vs the repo's committed state (2026-07-22, post-#65)
The catalog delivered **trustee-operator v1.2.1**; the committed v1.1-era Trustee wiring does
NOT work against it (issue #65 has the full analysis). The rig runs these deviations, all
applied by hand and pending back-port into `gitops/`/`scripts/`:
- KbsConfig: `kbsResourcePolicyConfigMapName` + `kbsAttestationPolicyConfigMapName` **removed**
  (v1.2.1 migration sweeper deletes any referenced policy CM unconditionally → deadlock).
  Built-in default policies active; rung-B measured policy must go in via the KBS API.
- `kbs-config` CM: **1.2-format toml** (authored live, source of truth = the live CM):
  `[admin] authorization_mode="DenyAll"`; unified `[storage_backend]` LocalFs at
  `/opt/confidential-containers/storage` (the operator's secret-converter/emptyDir layout);
  RVPS refs at `storage/local_json/reference_value`; `[attestation_token] insecure_key=true`
  + `trusted_certs_paths=["/etc/kbs-config/trust.pem"]` (PEM shipped as a 2nd CM key —
  RH build refuses an empty trust list); no `[policy_engine]`. The `.v1.1` backup CM must
  EXIST for `kbs-config` to survive reconciles — do not delete it.
- Node knobs (survive-reboot status checked by automation): kata
  `create_container_timeout=600` + `debug_console_enabled=true` in
  `/etc/kata-containers/{,kata-snp/}configuration.toml` (node-direct edits); kubelet
  `runtimeRequestTimeout=20m` via KubeletConfig `coco-runtime-request-timeout` (durable).
- **KataConfig `spec.logLevel: debug` is ACTIVE and on this OSC build it is MCO-plumbed**:
  patching it rendered a new `rendered-master` MachineConfig → drain + reboot (22:05 UTC),
  contrary to the OSC 1.12.0 source (daemonset + live crio reload). Leave it at `debug` —
  reverting costs another reboot. Drop-in shape here: nested `[crio] [crio.runtime]`.
- **⚠️ Air gap is NOT reboot-stable (#66):** post-reboot the `inet airgap` nft table was
  silently wiped while `airgap-egress.service` read success; quay was reachable until a
  manual `systemctl start airgap-egress`. After ANY reboot or service churn, verify:
  `nft list table inet airgap` + `curl quay.io` must fail — unit status is not proof.

### Decisions
- **From-zero rebuild (2026-07-22):** prior rig is gone; nothing to resume.
- **Automation failures found + fixed live (2026-07-22):**
  1. `mirror_push` — `environment: REGISTRY_AUTH_FILE: ""` exports the var *empty*
     (Ansible cannot unset); current oc-mirror (distribution v3) panics on any set value.
     Issue #61 → PR #62 (`env -u` prefix). Live-proven: full push completed, mirror serves.
  2. `install_drive` clusterversion poll — unquoted jsonpath (contains a space) is
     shlex-split by `command.cmd`; every retry rc=1/empty, healthy install reported
     failed=1. Issue #63 → PR #64 (argv form). Live-proven: quoted invocation rc=0.
  Both PRs lint-green (ansible-lint production profile; repo CI does not path-match
  ansible) and **await user merge** (merge action classifier-denied for the agent).
  Until merged, `main`'s copies of both tasks are still broken — run those roles from the
  fix branches or merge first. Side effect of #63: the `public_console` role never ran
  (play died before it) — cluster console is bastion-only for now.
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
