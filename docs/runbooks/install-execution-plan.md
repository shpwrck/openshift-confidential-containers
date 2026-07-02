# Air-Gapped SNO + Confidential Containers Bring-Up — Execution Plan (SEV-SNP, Latitude.sh)

**Target:** OCP **4.20.18** · OSC **1.12** · Trustee **1.1** · TEE = **AMD SEV-SNP (Genoa)** · Single-Node OpenShift on disposable Latitude bare metal, behind a persistent mirror bastion.

This is the disposable verification rig that proves each CoCo capability (secret release → measurement verification → signed image → encrypted image) under a *real* air gap before any of it touches a production cluster. For a fresh rig, start at Phase 0 and treat every stop-gate below as live. Current state: the SNO/Trustee rig is up, rung-signed has scoped happy/unsigned-denial evidence, and rung-encrypted remains blocked on the direct CRI-O/Kata encrypted-image pull path tracked upstream ([cri-o/cri-o#10084](https://github.com/cri-o/cri-o/issues/10084)).

**Estimated total wall time:** ~5–7 h, of which **~1–2 h is the unattended mirror** (paid once; the bastion persists across node churn). **Billing note:** two hourly-billed bare-metal hosts (persistent bastion + disposable node) — every `terraform apply` starts hourly billing; destroy when done. **Hands-on note:** the BIOS recipe, the ISO boot, and the IPMI console are browser/console actions that require physical/console access — they cannot be automated from the CLI.

> **🛑 STOP-gate** = do not proceed until green.

---

## Before we start — prerequisites

Line these up **first**. ⛔ = hard blocker (the bring-up cannot start/continue without it).

- [ ] ⛔ **Latitude API token** — `export LATITUDESH_AUTH_TOKEN=…`. Dashboard → API keys (`https://www.latitude.sh/dashboard/api-keys`, login/2FA). Supply as an **env var, never in tfvars**. *Note: even teardown (Phase 7) needs this.*
- [ ] ⛔ **Bastion plan SKU** — currently `plan = ""` (`# FILL`, fail-closed). Run `lsh plans list` and pick the cheapest metal SKU with **≥ 200 GB disk** (no SNP needed). Also set hourly-vs-monthly billing.
- [ ] ⛔ **Red Hat pull secret** — `https://console.redhat.com/openshift/install/pull-secret` (Red Hat login). Used **only on the bastion** to populate the mirror; placed in `~/.docker/config.json`. **Never carried onto the node.** Also needed in Phase 5 to pull `coco-tools`.
- [ ] ⛔ **IPMI/KVM console access** (URL + user + pass) — the captured token in `infra/latitude/IPMI-ACCESS.md` expires (~12 h) and **will be stale**. Re-issue via dashboard / `POST /servers/{id}/remote_access`. Needed for BIOS (Phase 1) **and** ISO boot (Phase 3).
- [ ] ⛔ **SSH private key on the controlling host** — tfvars pin `<SSH_KEY_ID>` (`~/.ssh/id_ed25519`). SSH to the node/bastion is needed for *every* Phase-1 step and to read the mirror CA/password. The `.pub` also fills `install-config sshKey`.
- [ ] ⛔ **Base domain + cluster name** — `baseDomain` (e.g. `example.com`) + `metadata.name` (e.g. `sno-coco`); FQDN = `name.baseDomain`. Decide the naming **and ensure DNS resolves `api`, `api-int`, `*.apps`** (unresolvable `api-int` hangs bootstrap).
- [ ] ⛔ **Out-of-band Trustee admin keypair** (Phase 5) — generate the **ed25519 kbs-auth keypair** on a connected host, guard the private half (it authorizes resource registration). The other 4 secrets can be created routinely; this one is a deliberate trust decision.
- [ ] ⛔ **A connected host for VCEK collection** (Phase 5) — the rig node is egress-blocked, so VCEK `.der`s must be fetched from AMD KDS on an **internet-connected** machine and carried in. Provide that path.
- [ ] 🟡 **admin_cidr** — your workstation/VPN egress IP (e.g. `203.0.113.4/32`). Shipped *commented* (fail-closed). Only **bites** if the node is applied with `-var enforce_latitude_firewall=true`; otherwise inbound is open (a conscious tradeoff for a throwaway rig).
- [ ] 🟡 **Node SKU/site** — already pinned (`m4-metal-medium` / Genoa / NYC, proven once). Re-decide **only** if Genoa/NYC is out of stock. **Bastion site MUST equal node site** (virtual networks are site-scoped).

---

## Phase 0 — Prereqs / tooling + pre-spend file fixes
**Goal:** tooling on `PATH`, pull secret staged, tfvars fail-closed traps fixed, local scaffold checks green — all **before any spend**. **~30–45 min hands-on.**

| Step | What happens / command |
|---|---|
| Fetch pinned tooling | `make fetch-cli-tools` → `scripts/install-tools.sh` (oc / openshift-install / oc-mirror @ 4.20.18). Then `export PATH="$PWD/bin:$PATH"`. Run from the repo root. **VERIFY** `OCP_VERSION` matches `install/imageset-config.yaml`. |
| Stage the Red Hat pull secret | Download from `console.redhat.com/openshift/install/pull-secret`; place in `~/.docker/config.json` on the bastion (later). |
| Ensure internal git reachable | Host this repo's `gitops/` tree on internal git reachable from the bastion VLAN. |
| **Fix bastion tfvars OS drift** | `terraform.tfvars.example` line 7 ships `operating_system = "ubuntu_26_04_x64_lts"` — a verbatim copy boots the **wrong OS** and the Rocky-specific NM/dnf cloud-init silently fails → VLAN never comes up. Edit the active `terraform.tfvars` so OS starts with `rocky`. |
| **Pre-fill bastion SKU** | `lsh plans list` → pick the cheapest metal with ≥200 GB disk. Write `plan = "<sku>"` (no longer `""`). |
| **Verify local scaffold scripts** | `scripts/collect-vcek.sh`, `scripts/gen-rvps-veritas.sh`, and `make negative-test` are implemented, but their real evidence is hardware-bound. Before spend, run `make lint` to cover shell syntax and overlay builds. Then, on the rig, rerun the specific hardware targets in Phase 6. |
| **Pin floating image tags** | `install/imageset-config.yaml` carries `ubi-minimal:latest` and `coco-tools:1.12` (a floating train tag). Pin both to digests before mirroring or the signed and encrypted image tests aren't reproducible. |
| Fix cosmetic script header | `scripts/host-snp-check.sh` header still says "Ubuntu node" — update so the executor doesn't think it's the wrong script. |
| **🛑 STOP-gate** | Confirm: `./bin/oc version`, `./bin/openshift-install version`, `./bin/oc-mirror --help` all resolve; pull secret present; active bastion tfvars has `rocky` OS + non-empty `plan`; `make lint` is green. **Hard gate before any spend.** |

---

## Phase 1 — Provision (bastion FIRST, then node) + rung-0 SNP host gate + egress lockdown
**Goal:** persistent mirror bastion up, disposable SNP node up with SNP-host **re-proven on Rocky 10**, air gap **enforced**. **~30–60 min hands-on.**

| Step | What happens / command |
|---|---|
| **Finalize bastion tfvars** | Set `site`, `plan` (Phase 0), `admin_cidr` (if enforcing inbound), `name` in `infra/latitude/bastion/terraform.tfvars`. Hourly billing starts on apply. |
| Provision the **persistent bastion** | `export LATITUDESH_AUTH_TOKEN=…; cd infra/latitude/bastion && terraform init && terraform apply`. Rocky 10; mirror admin password **generated on-box (0600)**, never in TF state. |
| Wait for mirror bootstrap + capture outputs | `ssh rocky@<bastion-ip> 'tail -f /var/log/mirror-bootstrap.log'` until `/opt/mirror/MIRROR_READY` exists (`MIRROR_FAILED` = abort). Then `terraform output mirror_endpoint` / `node_hosts_entry` / `virtual_network_vid`; `ssh … sudo cat /opt/mirror/mirror-admin-password` and `…/ca/rootCA.pem`. **VERIFY** the quay pod starts under SELinux **enforcing** (`MIRROR_READY` only stamps after it captures the CA). If it won't start: `restorecon -Rv` the quayRoot — **do NOT `setenforce 0`**. |
| **Provision the disposable node** | `cd infra/latitude && terraform init && terraform apply; terraform output ssh_hint`. Joins the bastion VLAN + lockdown firewall via remote state. *(Standalone rung-0 only: `terraform apply -var air_gap=false`.)* Don't re-provision mid-phase — a fresh node = **default BIOS**. |
| **🔧 Set the SEV-SNP BIOS recipe** | Latitude dashboard → `POST /servers/{id}/remote_access` → browser IPMI/KVM → reboot → AMI Aptio: **Main → North Bridge → `SEV-SNP Support` = Enabled** ⭐ (**NOT Auto — Auto reads as OFF, THE landmine**); Advanced → CPU Config: `SMEE`=Enabled, `SNP Memory (RMP Table) Coverage`=Enabled, `SEV-ES ASID Space Limit`=100, `SEV Control`=Enabled; **disable Memory Interleaving** (else PSP Error 0x3). The misleading `IOMMU SNP feature not enabled` message is caused by `Auto` — **don't chase IOMMU.** |
| Confirm node login user | Node `ssh_hint` says `ssh root@…`; bastion uses `rocky@…`. **VERIFY on first connect** — try `rocky@`, fall back `root@` (IPMI serial console is the last resort). All later SSH steps depend on this. |
| **Rung-0 host gate (Rocky 10)** | `ssh <user>@<ip> 'sudo bash -s' < scripts/host-snp-check.sh` — expect all PASS / `RESULT: SEV-SNP host LIVE`. The script **discriminates** kernel-incapable vs BIOS-off vs genuine provider-veto — read the `RESULT` line; a FAIL is **not** automatically a provider veto. |
| Bring up node VLAN L3 + mirror host entry | **VERIFY parent iface** (`ip -br link` — hardware-bound, assume `bond0` but confirm). `vid` from `terraform output virtual_network_vid`: `ssh <user>@<node-ip> 'sudo ip link add link bond0 name bond0.<vid> type vlan id <vid>; sudo ip addr add 192.168.66.11/24 dev bond0.<vid>; sudo ip link set bond0.<vid> up; echo "192.168.66.10 mirror.rig.local" | sudo tee -a /etc/hosts'` |
| Lock egress **host-side** with nftables | Latitude firewall egress direction is undocumented — **don't rely on it.** Default-deny output except the bastion private IP: `ssh <user>@<node-ip> 'sudo nft -f -'` with `table inet airgap { chain output { type filter hook output priority 0; policy drop; ct state established,related accept; oifname "lo" accept; ip daddr 192.168.66.10 accept } }`. *(Inbound is the separate opt-in Latitude firewall — don't conflate.)* |
| **VERIFY the air gap bites** | `curl -m5 -sI https://quay.io >/dev/null && echo EGRESS_OPEN_bad || echo EGRESS_BLOCKED_good` **AND** `curl -m5 -skI https://mirror.rig.local:8443 >/dev/null && echo MIRROR_OK_over_VLAN`. A silently-reachable internet would hide the VCEK-OfflineStore bug — **do not record the air gap as proven** until public egress is BLOCKED and the mirror answers. |
| **🛑 STOP-gate** | Both green: `host-snp-check.sh` all-PASS **and** egress-blocked + mirror-reachable. |

> **Billing branch at the rung-0 gate:** if `host-snp-check.sh` reports a **kernel/image** FAIL (Rocky 10's 6.12 lacks the SNP-host param) — **immediately `terraform destroy` the node (or re-provision with the proven Ubuntu image / `operating_system=ipxe`) before any further debugging.** The node is billed hourly. Only a **genuine provider/firmware veto** (kernel-capable + BIOS-on, still fails) triggers the design §6 fallback.

---

## Phase 2 — Mirror the content to the bastion (the bottleneck)
**Goal:** all release + operator content mirrored to the bastion registry, cluster-resources captured. **~1–2 h unattended (runs on the bastion).**

| Step | What happens / command |
|---|---|
| **VERIFY operator channels FIRST** | Cheap to verify, 1–2 h to redo. For each of NFD / cert-manager / OSC / Trustee: `oc-mirror list operators --catalog <idx> --package <name>`; reconcile channels in `install/imageset-config.yaml` (all carry `# VERIFY`; defaults: sandboxed=stable, trustee=stable, nfd=stable, cert-manager=stable-v1). Confirm `OCP_VERSION 4.20.18` exists in `stable-4.20`. **Hard pre-mirror gate, not advisory.** |
| Stage pull secret + run the mirror | RH pull secret in `~/.docker/config.json` on the bastion. `export MIRROR_REGISTRY=$(cd infra/latitude/bastion && terraform output -raw mirror_endpoint); make mirror-content` (oc-mirror `--v2`). **Cacheable** — `./mirror` workspace persists; re-runs fetch deltas. **Landmines:** 401/403 = stale RH pull secret; x509 = mirror CA not trusted on the push host (`curl -v https://mirror.rig.local:8443/v2/`). |
| **Extract the air-gapped installer binary** | The real `openshift-install` should match the mirrored payload byte-for-byte: `oc adm release extract --command=openshift-install` against the **mirror**, then repoint `INSTALL=` (Makefile default is `./bin/openshift-install`, the *public* binary). *Decision: the rig MAY accept the public binary — state the tradeoff if you skip this; enforce byte-match before production work.* |
| Locate cluster-resources (apply LATER) | `MIRROR_REGISTRY=… ./scripts/mirror.sh resources` → lists `./mirror/working-dir/cluster-resources/` (IDMS/ITMS + CatalogSource). **Do NOT `oc apply` yet** — the installer uses `install-config imageDigestSources`, not these. |
| **🛑 STOP-gate** | `make mirror-content` exit 0 **AND** cluster-resources YAML present **AND** all four operator packages are confirmed *in* the mirrored catalog (the pre-mirror `oc-mirror list` proved this). |

> *(Runs unattended on the bastion.)*

---

## Phase 3 — SNO install via Agent-based Installer
**Goal:** single node Ready, mirrored CatalogSource present. **~45 min build+boot, then ~30–45 min unattended.**

| Step | What happens / command |
|---|---|
| Gather node hardware facts | `ssh <user>@<node-ip>`: `lsblk` (root device `/dev/nvme0n1` vs `/dev/sda`), `ip link` (real NIC MAC — **never guess**), confirm static IP/gw/DNS/machineNetwork CIDR, `timedatectl` (clock). |
| Fill templates into a fresh assets dir | `mkdir -p cluster-assets; cp install/*.tmpl …`. **install-config:** `baseDomain`/`metadata.name`, `machineNetwork` CIDR, `imageDigestSources` (MIRROR_REGISTRY + the two oc-mirror paths), `additionalTrustBundle` (bastion `rootCA.pem`), `pullSecret` (**MIRROR** creds base64 `user:pass` — **NOT** the RH cloud secret), `sshKey`. Keep `.tmpl` as source of truth; edit copies only. |
| **Author the VLAN + mirror-resolution into agent-config** | ⚠️ **The template ships only a flat `eno1` on `192.168.1.x` — there is NO VLAN child, NO `192.168.66.11`, NO mirror host entry to "fill."** You must **author** an nmstate **VLAN interface** (`bond0.<vid>`) carrying `node_vlan_ip 192.168.66.11`, plus mirror-name resolution. The Phase-1 `/etc/hosts` trick was on the wiped Rocky host and **does NOT carry into RHCOS** — resolve `mirror.rig.local` via RHCOS nmstate static-host/DNS (or a MachineConfig), not `/etc/hosts`. Set `rendezvousIP` (=node IP), `hostname`, `rootDeviceHints.deviceName`, `interfaces[].macAddress`. **This is the single most likely "install never starts" trap.** |
| **Wire NTP to the bastion** | Clock skew silently hangs bootstrap **and** breaks SNP attestation; the air-gapped node can't reach public NTP. Set the **bastion as an NTP source** (`additionalNTPSources` in install-config / chrony in agent-config) and **verify the bastion actually serves time** — currently neither is wired. |
| Build the agent ISO | `make agent-image` → `cluster-assets/agent.x86_64.iso`. (Uses the air-gapped `INSTALL` binary from Phase 2 if you extracted it.) |
| **💿 Boot the node from the ISO** | Latitude IPMI/KVM → attach `agent.x86_64.iso` as virtual CD, set **one-time boot** to virtual CD, reboot. **Fallback** if vmedia mount quirks: custom **iPXE** chain-load from the bastion (`agent create pxe-files`). |
| Wait for completion | `make install-wait` (`agent wait-for install-complete`; optionally `bootstrap-complete` first). **Run from a host with VLAN line-of-sight to `api-int.<cluster>.<base>`** — the public-side admin host may not reach it; **run the wait from the bastion** if so. Kubeconfig → `cluster-assets/auth/`. *Hang at bootstrap usually = DNS / egress / wrong imageDigestSources / clock skew.* |
| Apply mirror cluster-resources | `export KUBECONFIG=cluster-assets/auth/kubeconfig; oc apply -f ./mirror/working-dir/cluster-resources/`. |
| **🛑 STOP-gate** | `oc get nodes` → single node **Ready**; `oc get catalogsource -n openshift-marketplace` → mirror catalog present **and READY**. *(CatalogSource not READY in disconnected = zero operators install.)* |

> **Console action this phase:** attach the ISO and trigger the boot via IPMI virtual media (or the iPXE fallback). Confirm DNS for `api`/`api-int`/`*.apps` resolves over the VLAN.

---

## Phase 4 — Operators (NFD → cert-manager → OSC → Trustee) + KataConfig (node reboot)
**Goal:** four CSVs Succeeded, node back Ready after a self-reboot, `kata` + `kata-cc` RuntimeClasses present. **~30–45 min mixed.**

| Step | What happens / command |
|---|---|
| **RHCOS SNP host gate** | `make verify-snp-host NODE=<node-name>` — checks PSP SEV-SNP API, RMP table, no Error 0x3, `kvm_amd sev_snp=Y`, `/dev/sev`. **🛑 HARD STOP — do not apply any GitOps until green.** Rung-0 only proved the raw Rocky kernel; this proves the *RHCOS* kernel. |
| **Reconcile CRD field-name guesses (BLOCKING)** | `gitops/base/**` was authored from docs, **not live CRDs** — the most likely first bite. The moment OSC/Trustee CSVs install: `oc explain kataconfig.spec` (OSC 1.12 uses the `osc-feature-gates` ConfigMap for CoCo; there is no `enableConfidentialCompute` field), `oc explain kbsconfig.spec` (incl. `kbsLocalCertCacheSpec` @ trustee v1.1). Correct manifests **before** trusting overlays. |
| Apply the workers overlay | `make install-coco-operators` (`oc apply -k gitops/overlays/sno-workers`). Wait: `oc get csv -A | grep -Ei 'nfd|cert-manager|sandboxed|trustee'` until all **Succeeded**. Order NFD→cert-manager→OSC→Trustee is load-bearing (enforced by `subscriptions.yaml`). **VERIFY** mirrored CatalogSource name/channels. **NFD must label the node `SEV_SNP`** or KataConfig binds the wrong handler — **do NOT hand-label** (masks the fault). |
| KataConfig reboots the single node | Applying `kataconfig.yaml` triggers an MCP rollout that **self-reboots** the SNO (no spare node — wait it out): `oc get mcp -w`. |
| Verify RuntimeClasses (the proof) | `oc get runtimeclass` → expect `kata` AND `kata-cc`; `oc get runtimeclass kata-cc -o jsonpath='{.handler}'` must be **`kata-snp`**. |
| **🛑 STOP-gate** | Four CSVs Succeeded, node Ready post-reboot, `kata` + `kata-cc` (handler `kata-snp`) present. *If handler ≠ `kata-snp`, KataConfig ran before NFD labeled — re-apply KataConfig after the label exists.* |

---

## Phase 5 — Air-gap attestation data (hardware-bound: VCEK OfflineStore + RVPS)
**Goal:** node egress locked on RHCOS (air gap made real), then KBS up with the VCEK OfflineStore mounted and RVPS reference values loaded. **~30–45 min hands-on, hardware-bound.**

| Step | What happens / command |
|---|---|
| **Lock node egress (make the air gap real) — do this FIRST** | Phase 1's nft locked the *raw Rocky OS*; the Phase 3 install **wiped it**, so the RHCOS node is currently egress-OPEN. Re-establish it now that the cluster is healthy: `oc apply -k gitops/base/airgap-egress` (an opt-in MachineConfig — deliberately kept out of the install overlay so a half-formed drop policy can't wedge bootstrap; safe to apply now). **VERIFY from the node** — `oc debug node/<node-name> -q -- chroot /host curl -m5 -sI https://quay.io` must **FAIL/timeout**, while `oc get co && oc get nodes` stay healthy. **Multi-node customer:** flip the MachineConfig `role: master`→`worker` first (it targets the SNP worker pool, not the control plane). **Why before the rungs:** if egress is still open at Phase 6, the air-gap negative test can **falsely pass by reaching the public KDS** — the exact false-positive this whole engagement exists to prevent. |
| **Create the 5 out-of-band Trustee secrets FIRST** | KBS crash-loops (looks like an attestation bug) if these are missing — create them **before** `make deploy-trustee`. Per `gitops/base/trustee/secret-stubs.example.yaml`: `kbs-auth-public-key` (supply/guard the ed25519 admin keypair, then `oc create secret`), `attestation-cert`, `regcred` (**name must NOT contain dots**), `sample`. |
| Stand up the rig Trustee | `make deploy-trustee` (`oc apply -k gitops/overlays/sno-trustee`). |
| **Collect VCEK certs (lowercase HWID)** | `make collect-vcek NODE=<node-name>` collects the **master** socket's VCEK, keyed by **LOWERCASE** HWID (`tr A-Z a-z`), fetched via `snphost show vcek-url` → downloaded **on the connected host** → carried in. Generation-agnostic (dodges Trustee #591 Milan hardcode). Secrets are `vcek-snp-<hwid-prefix>` (stable, not positional). **2P boxes:** host-side tools yield only the master socket; each other socket's VCEK comes from an **SNP report on that socket** (`scripts/collect-vcek.sh --from-report`) — see [`multi-socket-vcek.md`](multi-socket-vcek.md), else socket-N CVMs fail attestation. **Landmine: an UPPER-case HWID silently misses the cache and falls through to the (unreachable) KDS → attestation fails for the wrong reason.** |
| Generate RVPS with Veritas | `make gen-rvps` (`coco-tools` pinned by digest, `veritas --tee snp --ocp-version <OCP_VERSION>`, one run per distinct socket/hardware config). Re-run if initdata changes or KBS reports measurement mismatch. In disconnected rigs, set `DEBUG_IMAGE` to a cached node-debug image and use `VERITAS_OC_WRAPPER` only when the bundled Veritas/`oc adm release info` path still hard-codes public release refs. |
| Wire both into Trustee | VCEK secrets mounted at `…/kds-store/vcek/<hwid>/vcek.der` via `KbsConfig.spec.kbsLocalCertCacheSpec`; RVPS merged into the `rvps-reference-values` ConfigMap (per `kbsconfig.yaml`). **Ensure `vcek_sources` omits `{type=KDS}`** — leaving KDS in lets it "work" by reaching an internet that won't exist in production. (Field names already reconciled in Phase 4.) |
| **🛑 STOP-gate** | `oc logs -n trustee-operator-system -l app=kbs --tail=100 | grep -Ei 'warn|error|deny|reject|measurement'` → no missing-cert / empty-RVPS errors; KBS restarts cleanly. |

---

## Phase 6 — Rungs A → B → C → D (each proven only when reproduced AND its negative test passes)
**Goal:** every rung's happy path **and** negative test pass, plus the air-gap VCEK-pull negative test. **~1–2 h hands-on, strictly in order.**

Rung-kbs and the air-gapped guest-pull path have a proven recipe. **Rung-rvps (measurement
verification) is proven** via the measured-initdata negative (untampered released / tampered
withheld, 2026-07-01). **Rung-signed (signed image) is proven** on the rig via the keyprovider-free
build path (2026-07-01). **Rung-encrypted (encrypted image)** has tag-shaped diagnostics for guest
decryption and measured-initdata key gating, but the direct digest-pinned encrypted-image pod is
still blocked by CRI-O host-side encrypted-layer pre-pull before Kata guest pull begins; the upstream
blocker is tracked at [cri-o/cri-o#10084](https://github.com/cri-o/cri-o/issues/10084). Rung-encrypted
is **MANUAL and excluded from the hands-off loop — a skipped D is not a failure.** See the Phase 6
table below for the exact build/apply/negative sequence.

| Step | What happens / command |
|---|---|
| **Rung A (rung-kbs) — secret release** | Deploy `gitops/base/workloads/rung-a-secret-pod.yaml` (`runtimeClassName: kata-cc`). **Happy:** init `curl …/cdh/resource/default/attestation-status/status` → success → workload runs. **Negative (the proof):** `make negative-test WHICH=rung-kbs` fails closed with **no valid attestation** → secret **withheld** (HTTP 403). **Landmine:** keep `limits.memory ≥ default_memory + 256–512 MiB` or the host **OOM-kills the CVM** (DeadlineExceeded, QEMU dies in seconds). Primary signal: container status + `oc get events` + logs, **not** `oc describe pod` (it echoes the spec). |
| **Rung B (rung-rvps) — measurement verification** | The RVPS `snp_launch_measurement` is populated (Phase 5) so a valid attestation only releases when its measurement matches. **Negative (the measurement proof):** `make negative-test WHICH=rung-rvps` is **self-contained** (mirrors the air-gap swap-and-restore) — it backs up the base policies, applies a **restrictive measured-initdata policy** (the secret is released only when `input.init_data` equals the sha256 of the exact initdata bytes), confirms the **untampered** pod still releases (a control that makes a false-pass impossible), then deploys a **tampered-initdata** pod which is **withheld** (HTTP 403), and restores the base policies. **Proven on the rig 2026-07-01: untampered RELEASED, tampered WITHHELD, base restored.** *(after rung A)* |
| **Rung C (rung-signed) — signed image** | **Keyprovider-free path (recommended in an air gap):** `make build-rung-signed` (skopeo copy + cosign sign — no `coco-keyprovider`; writes `rung-image-artifacts/rung-signed.env` with the pushed digest refs), then `source rung-image-artifacts/rung-signed.env` and `make deploy-trustee-rung-signed` + `make run-rung-signed` (both consume `RUNG_SIGNED_IMAGE` = the `@sha256:` digest ref that `apply-rung-image.sh` requires). (`make build-rung-images` also builds the signed image, but it bundles the encrypted image and **requires `coco-keyprovider`**, which isn't in the mirror and can't be built in-gap — see follow-ups.) **Happy:** signed image pulls (mirror pull secret served as `regcred`). **Negative:** `make negative-test WHICH=rung-signed RUNG_SIGNED_UNSIGNED_IMAGE=<unsigned-digest-ref>` must fail closed through `image_security_policy` rejection. `regcred` name **without dots**; registry CA in initdata as **separate array elements**; policy must allow/verify pause/release images too. **Proven on the rig 2026-07-01 via the keyprovider-free path.** *(after rung B)* |
| **Rung D (rung-encrypted) — encrypted image** *(MANUAL / upstream-blocked — excluded from the hands-off loop)* | Use the same artifacts, then `make deploy-trustee-rung-image` and `make run-rung-encrypted RUNG_ENCRYPTED_IMAGE=<digest-ref>`. **Happy:** pod Running (image key released after attestation from `image-key/rung-encrypted`). **Negative:** `make negative-test WHICH=rung-encrypted RUNG_ENCRYPTED_IMAGE=<digest-ref>` must fail closed from a measured-initdata mismatch, not from a missing key. **⚠ upstream-blocked** (direct encrypted-image pull gated on cri-o/cri-o#10084 — the known frontier); **a skipped D is not a loop failure.** *(after rung C)* |
| **Air-gap negative test** | `make negative-test WHICH=air-gap`. The harness **swaps each Trustee `vcek-*` Secret for a valid-but-wrong self-signed cert** (KBS stays up — *deleting* the required-volume secret would only crash-loop KBS, which is **not** the same as attestation-denied), reruns an otherwise happy rung-kbs request, then restores the real certs. Attestation **must FAIL** (on the rig: `POST /kbs/v0/attest 401`, "Certificate chain from KDS failed verification") — proving the OfflineStore cache, not a leaky KDS, is load-bearing. **Precondition: node egress must be locked (Phase 5, step 1)** — with egress open, a wrong cached cert can still be silently "fixed" by reaching the public KDS and the test **falsely passes**. **If a negative test PASSES (secret released when it shouldn't), that's a real, sign-off-blocking finding** — policy/RVPS not actually wired; fix before sign-off. |
| **🛑 STOP-gate** | All rung A/B/C happy+negative results green **and** the air-gap VCEK-pull negative test fails-closed as expected (rung D is MANUAL/upstream-blocked — a skipped D is not a gate failure). Confirm each rung's happy + negative result on the node before sign-off. |

> **Per-rung negatives (#17/#18, wired):** each rung has its OWN denial — `WHICH=rung-kbs` = **bare attestation** (a non-CoCo / non-kata pod has no CVM, so it cannot attest → the KBS secret is withheld, #17); `WHICH=rung-rvps` = **measurement** (valid attestation but wrong/absent measured-initdata → withheld, #18 — the appraised measurement is `HOST_DATA == sha256(initdata)` carried in the SNP report; populate the `snp_launch_measurement` RVPS reference values per-rig with `make gen-rvps`, keeping `gitops/base` permissive `[]`, production regenerates its own); `WHICH=rung-signed` = signature; `WHICH=air-gap` = VCEK/OfflineStore. `WHICH=all` = kbs + rvps + signed + air-gap (rung-encrypted / D is manual).

---

## Phase 7 — Teardown (stop node billing; keep the bastion/mirror)
**Goal:** node billing stopped, bastion mirror preserved. **~5 min hands-on.**

| Step | What happens / command |
|---|---|
| **Confirm teardown** | Decide the spike is done for the node. Bastion stays up so the mirror persists. |
| **Pre-flight the teardown deadlock** | The node module reads bastion remote state on **every** op incl. `destroy`. **First:** `test -f infra/latitude/bastion/terraform.tfstate`. **Ordering constraint: always destroy the NODE before the bastion.** |
| Destroy ONLY the node | `cd infra/latitude && terraform destroy` (stops node billing; leaves the bastion). **If state is missing/moved:** `terraform destroy -refresh=false`, **or** kill the server from the Latitude dashboard. |
| Note for next spike | Re-provisioning gives a **fresh node with DEFAULT BIOS** — the Phase-1 SNP BIOS recipe must be **re-applied every time**. Destroy the **bastion** (`cd infra/latitude/bastion && terraform destroy`) only at the **very end of the project**. |

> **Reminder:** if the node `destroy` deadlocks on missing bastion state and the `-refresh=false` path also fails, kill the server from the Latitude dashboard to stop billing.

---

## Decision points — quick reference

| Decision | Options | Default / recommendation | When |
|---|---|---|---|
| Bastion plan SKU | any cheap metal w/ ≥200 GB disk | agent proposes via `lsh plans list`; **you pick cheapest** | Phase 0 / 1 |
| Bastion billing | hourly / monthly | **monthly** if it runs for the whole project | Phase 1 |
| `admin_cidr` | your `/32` · `0.0.0.0/0` (knowingly) | your workstation `/32`; only bites if `enforce_latitude_firewall=true` | Phase 1 |
| Inbound enforcement | `enforce_latitude_firewall` true/false | **false** for throwaway rig (conscious open-inbound tradeoff) | Phase 1 |
| Node OS on rung-0 FAIL | Rocky 10 / proven Ubuntu 26.04 / `operating_system=ipxe` | fall back to Ubuntu **only** if Rocky is kernel-incapable; **destroy first to stop billing** | Phase 1 gate |
| `openshift-install` binary | public (`install-tools`) / `oc adm release extract` from mirror | rig **may** accept public; **enforce byte-match before production** | Phase 2→3 |
| Mirror-name resolution on RHCOS | nmstate static-host / DNS / MachineConfig | nmstate in agent-config (the `/etc/hosts` trick does NOT carry to RHCOS) | Phase 3 |
| Post-install egress control | author `machineconfig-egress-nft.yaml` / VLAN-only-routing + no default route | **de-scope to VLAN-only-routing** for the rig and state it; the nft→MachineConfig is an **unwritten deliverable** (no manifest exists in `gitops/`) | Phase 3+ |
| `vcek_sources` KDS entry | OfflineStore only / +KDS | **OfflineStore only** (omit KDS) for a true offline test | Phase 5 |
| mirror-registry tarball | `latest` (unverified) / pinned URL+sha256 | rig MAY run unverified; **pin before production** | Phase 1 |

---

## Risk & VERIFY watchlist

| What to check | How | If it fails |
|---|---|---|
| **Rung-0 on Rocky 10** (kernel 6.12 unproven) | `host-snp-check.sh` → `RESULT` line | kernel/image FAIL → **destroy node now**, re-provision Ubuntu; genuine veto → design §6 (your call) |
| **BIOS `SEV-SNP Support` = Auto reads as OFF** | `host-snp-check.sh` reports `kvm_amd sev_snp=Y` only when correct | set **=Enabled** (not Auto) at IPMI; don't chase the `IOMMU` red herring |
| **Air gap enforced** | `curl quay.io` → BLOCKED; `curl mirror.rig.local:8443` → OK | repair nft ruleset / fix VLAN L3 before mirroring |
| **VLAN parent iface** (hardware-bound) | `ip -br link` on **both** hosts | set `vlan_parent_interface` to real name, repair NM keyfile + node nft `oifname` |
| **quay under SELinux enforcing** | `test -s /opt/mirror/MIRROR_READY`; `ausearch -m avc -ts recent` | `restorecon -Rv` quayRoot; **never `setenforce 0`** |
| **Operator channels** before the 1–2 h mirror | `oc-mirror list operators --catalog <idx> --package <name>` ×4 | fix channel strings in `imageset-config.yaml` before paying the bottleneck |
| **Mirror x509 / additionalTrustBundle** | `curl -v https://mirror.rig.local:8443/v2/` from bastion + node | add CA to host trust; paste PEM into `additionalTrustBundle`; pullSecret = MIRROR creds |
| **agent-config VLAN + mirror resolution exists** | inspect `cluster-assets/agent-config.yaml` for the `bond0.<vid>` child + mirror host | author it (template ships only flat `eno1`) — else install never starts |
| **NTP / clock sync** | `timedatectl` node+bastion; bastion serves time | wire `additionalNTPSources` to bastion; skew hangs bootstrap + breaks attestation |
| **install root device / MAC / rendezvousIP / DNS** | `lsblk`, `ip link`, `ip a`, `dig api-int…` | fill agent-config from observed values; never guess MAC |
| **CatalogSource READY** (disconnected) | `oc get catalogsource -n openshift-marketplace` | apply cluster-resources; fix CatalogSource name/channels in `subscriptions.yaml` |
| **CRD field names** (KataConfig/KbsConfig guesses) | `oc explain kataconfig.spec` / `kbsconfig.spec` once CSVs Succeed | CoCo is the `osc-feature-gates` ConfigMap (no `enableConfidentialCompute` field in 1.12); correct `kbsLocalCertCacheSpec`, re-apply |
| **NFD `SEV_SNP` label** | `oc get nodes -o json | jq '..labels' | grep -i sev_snp`; `kata-cc` handler = `kata-snp` | wait for NFD, re-apply KataConfig; **do NOT hand-label** |
| **CVM OOM-kill** | `limits.memory ≥ default_memory + 256Mi`; `dmesg | grep -i oom` | raise `limits.memory` (+512Mi safe) |
| **HWID lowercase** | secret keys match `kds-store/vcek/<hwid>` exactly; KBS logs no OfflineStore miss | lowercase the HWID, one VCEK per socket |
| **Two proxies / time** | both Trustee `KbsEnvVars` **and** in-CVM `aa.toml`/`cdh.toml`; NTP reachable | set both proxies (neither inherits cluster proxy); fix NTP to bastion |
| **Teardown deadlock** | `test -f infra/latitude/bastion/terraform.tfstate` before destroy | `-refresh=false` or dashboard-kill; always node-before-bastion |

---

## Definition of done — per rung

A rung is **proven only when reproduced from the written steps AND its negative test fails-closed** (design §5). All preconditions: Phase-1/4 SNP-host gates green, air gap enforced (public egress dead), KBS up with OfflineStore + RVPS.

> **Automated proof runner (#21):** `make test-rung WHICH=all` runs BOTH proofs per rung — the **positive** (happy-path apply; fail-OPEN: secret released / signed image runs) and the **negative** (denial; fail-CLOSED, delegated to `negative-test.sh`). It reports rung-kbs (bare attestation), rung-rvps (measurement), and rung-signed green, with **rung-encrypted manual** (upstream-blocked, #20) — a skipped/manual rung is not a failure. Pass the built digest refs `RUNG_SIGNED_IMAGE=<…@sha256:…>` and `RUNG_SIGNED_UNSIGNED_IMAGE=<…@sha256:…>` for the rung-signed proofs. Each negative backs up + restores its policy/VCEK, so the rig returns to baseline; `make negative-test WHICH=…` still runs the denial-only suite.
>
> **Hands-off repro loop (#22):** `make repro-loop` chains deploy → positive → negative for **A → C** with no manual steps, then the air-gap negative. It writes a **durable, resumable** status file (`loop-runs/repro-status.tsv`, git-ignored) — an interrupted run resumes at the first not-yet-PASS rung instead of restarting from A; `make repro-loop REPRO_FRESH=1` starts a new run. It **stops on the first hard failure** so the finding surfaces; rung-rvps (B) skips until #18 and rung-encrypted (D) is logged-skipped (manual). Exit 0 = A→C green.
>
> **Post-#16 rig migration:** the capability rename moved the signed KBS resources to `security-policy/rung-signed` + `sig-public-key/rung-signed`. An existing rig seeded before #16 must re-seed once — `make seed-rung-signed-secrets` (idempotent; VCEK re-seed is a no-op when `VCEK_BUNDLE` matches) then restart the Trustee deployment — or the rung-signed pod fails with `[CDH] Get resource failed`.

**Rung A (rung-kbs) — secret release**
- ✅ Happy: `cdh/resource/.../attestation-status` → `{"status":"success"}`; pod runs.
- ✅ Negative: no valid attestation → **error, secret withheld (HTTP 403), pod does not start.**

**Rung B (rung-rvps) — measurement verification**
- ✅ Happy: valid attestation with the expected measurement → secret released; pod runs.
- ✅ Negative: restrictive measured-initdata policy + wrong/absent measurement (tampered initdata) → **error, secret withheld (HTTP 403), pod does not start.**

**Rung C (rung-signed) — signed image**
- ✅ Happy: signed image pulls (mirror pull secret served as `regcred`).
- ✅ Negative: unsigned/tampered image → `image_security_policy` **rejects** the pull.

**Rung D (rung-encrypted) — encrypted image** *(MANUAL / upstream-blocked: cri-o/cri-o#10084 — excluded from the hands-off loop; `make test-rung`/`WHICH=all` report it skipped, never failed)*
- **Manual pre-step (why it's not hands-off):** encrypt the image layer (`coco-keyprovider`, which isn't in the mirror and can't be built in-gap) and register its decryption KEK as the KBS resource `image-key/rung-encrypted` (`make build-rung-images` + `make deploy-trustee-rung-image`). Workload `gitops/base/workloads/rung-encrypted-pod.yaml` (pod `rung-encrypted`).
- ✅ Happy: pod reaches `Running` (image key released after attestation).
- ✅ Negative: wrong measurement → key withheld → **pod won't start.**
- **⚠ upstream block:** direct host pre-pull of the encrypted layer is gated on cri-o/cri-o#10084 — so run D by hand (`make run-rung-encrypted` / `make negative-test WHICH=rung-encrypted`), and treat a skipped D as *not* a sign-off failure.

**Air-gap (cross-cutting)**
- ✅ Negative: remove one VCEK / wrong-case HWID → **attestation fails** — proving the OfflineStore cache, not a silently-reachable KDS, is load-bearing.

> A negative test that **passes** (secret released when it shouldn't) is **not** a pass — it means policy/RVPS isn't actually enforcing. Treat it as a **sign-off-blocking finding**, not a green.

---

**Relevant repo paths:** `docs/runbooks/disconnected-sno-bringup.md` (backbone), `docs/runbooks/failure-modes.md`, `docs/design/engagement-design.md` (§5 negative-test matrix, §6 fallback), `Makefile`, `install/{README.md,install-config.yaml.tmpl,agent-config.yaml.tmpl,imageset-config.yaml}`, `infra/latitude/{bastion/,outputs.tf}`, `scripts/{install-tools.sh,host-snp-check.sh,mirror.sh,verify-snp-host.sh,collect-vcek.sh,gen-rvps-veritas.sh}`, `gitops/base/{operators/subscriptions.yaml,kataconfig/kataconfig.yaml,trustee/{kbsconfig.yaml,secret-stubs.example.yaml},workloads/rung-a-secret-pod.yaml}`.
