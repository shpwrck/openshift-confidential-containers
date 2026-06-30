# Runbook — Disconnected SNO + Confidential Containers bring-up (SEV-SNP)

The ordered, end-to-end procedure for standing up the air-gapped single-node OpenShift
(SNO) Confidential Containers verification rig **tomorrow, on real hardware**. It sequences
the install kit (`install/`), the GitOps tree (`gitops/`), the hardware-bound pipelines
(`scripts/`), and the rig driver (`Makefile`).

Targets: **OCP 4.20.18** (alt 4.19.28), **OSC 1.12**, **Trustee 1.1**, TEE = **AMD SEV-SNP**.
Background: [`../design/engagement-design.md`](../design/engagement-design.md).

## How to read this

- Each phase links the **real file / `make` target** it drives and flags whether it is
  **hands-on** (you babysit it) or **unattended** (kick off, walk away), with a rough wall time.
- **STOP-gates** are hard: do not proceed past one until it is green.
- `# VERIFY` / `# FILL` markers in the linked files are host- or version-specific. Resolve
  them on the node — do not invent values.
- This is the **rig** path (`oc apply` via the `Makefile`). The production environment points
  mirrored ArgoCD at the same `gitops/` tree instead; the manifests are identical.

### What's hardware-bound vs portable

Carry this distinction through every phase (source: [`../../gitops/README.md`](../../gitops/README.md),
design §4):

- **Portable** — prove once on the rig, reuse verbatim on production metal: all `gitops/`
  manifests, operator subscriptions + **install order** (NFD → cert-manager → OSC → Trustee),
  KBS ConfigMaps, Rego policies, initdata *structure*, the `Makefile`/`scripts` themselves.
- **Hardware-bound** — must be **regenerated on each distinct CPU+firmware config**: VCEK
  certs (keyed by chip HWID), RVPS reference values (CPU family + firmware), TLS certs +
  Trustee URL, initdata *measured bytes* (HOST_DATA), and the BIOS recipe. These are Phases
  1, 5, and the per-overlay `# FILL`s.

---

## Phase 0 — Prereqs (hands-on, ~30 min, one-time)

Done on the **bastion / admin host**, not the node.

- [ ] **Fetch pinned tooling:** `make tools` → [`scripts/install-tools.sh`](../../scripts/install-tools.sh)
      pulls `oc`, `openshift-install`, `oc-mirror` (all 4.20.18 / linux-amd64) into `./bin`.
      Then `export PATH="$PWD/bin:$PATH"`.
      `# VERIFY` `OCP_VERSION` matches the [`install/imageset-config.yaml`](../../install/imageset-config.yaml) pin.
- [ ] **Bastion with the mirror registry — now Terraform-automated** via
      [`../../infra/latitude/bastion/`](../../infra/latitude/bastion/): a persistent Latitude host
      that cloud-init bootstraps with Red Hat `mirror-registry` (quay). It is a **separate, longer-
      lived module** from the SNP node so the ~1–2 h mirror is paid **once** and survives node
      churn. Apply it **before** the node (Phase 1). It emits the **CA** (`<mirror_root>/ca/rootCA.pem`)
      and the mirror **host:port** (`terraform output mirror_endpoint`). The node is later egress-
      restricted to reach **only** this bastion (see the Phase-1 firewall VERIFY).
- [ ] **Internal git** reachable from the bastion (and, in the production env, from ArgoCD)
      hosting this repo's `gitops/` tree.
- [ ] **Red Hat pull secret** from <https://console.redhat.com/openshift/install/pull-secret>
      — used to *populate the mirror* (Phase 2). It is **not** carried onto the air-gapped
      node; the node's `pullSecret` is the **mirror** credential only.

> STOP-gate: tooling on `PATH`, mirror registry up with a known CA, pull secret in hand.

---

## Phase 1 — Provision + rung-0 SNP host gate (hands-on, ~30–60 min)

Reference: [`../../infra/latitude/README.md`](../../infra/latitude/README.md),
BIOS recipe [`../notes/latitude-snp-bringup.md`](../notes/latitude-snp-bringup.md).

- [ ] **Provision the bastion first** (persistent; hourly bare-metal billing starts on apply), then the node:
      ```bash
      export LATITUDESH_AUTH_TOKEN=...
      # 1) persistent mirror/air-gap host (apply once; keep up across node spikes).
      #    The mirror admin password is GENERATED on the bastion — do NOT set it here.
      cd infra/latitude/bastion && terraform init && terraform apply
      terraform output mirror_endpoint   # DNS name:8443 -> MIRROR_REGISTRY for Phase 2
      terraform output node_hosts_entry  # "<bastion-vlan-ip> <mirror-name>" -> into agent-config (Phase 3)
      # retrieve the generated registry admin password once the bastion is up:
      ssh rocky@$(terraform output -raw bastion_public_ipv4) 'sudo cat /opt/mirror/mirror-admin-password'
      # 2) disposable SNP node (reads the bastion's VLAN + firewall via remote state)
      cd ..            && terraform init && terraform apply       # m4-metal-medium / Genoa / rocky-10 (rung-0 was proven on Ubuntu 26.04 — re-verify on Rocky)
      terraform output ssh_hint
      ```
      (Standalone rung-0 with no bastion: `terraform apply -var air_gap=false` in `infra/latitude/`.)
- [ ] **Set the SNP BIOS** via the Latitude browser IPMI/KVM (`POST /servers/{id}/remote_access`):
      reboot → AMI Aptio. The proven sequence (note §"BIOS settings"):
      - Main → North Bridge → **`SEV-SNP Support` = Enabled** ⭐ (the actual fix; `Auto` = off)
      - Advanced → CPU Config → **`SMEE` = Enabled**, **`SNP Memory (RMP Table) Coverage` =
        Enabled**, **`SEV-ES ASID Space Limit` = 100**, `SEV Control` Enabled.
      - The misleading `IOMMU SNP feature not enabled` kernel message is caused by
        `SEV-SNP Support = Auto`, **not** IOMMU — don't chase IOMMU.
- [ ] **Rung-0 host gate** — prove silicon+provider do SNP host, on the raw Rocky 10 node
      (pre-OpenShift), via [`scripts/host-snp-check.sh`](../../scripts/host-snp-check.sh):
      ```bash
      ssh rocky@<ip> 'sudo bash -s' < scripts/host-snp-check.sh   # expect all PASS
      ```
      The script **discriminates** kernel-incapable vs BIOS-off vs genuine provider-veto — a
      FAIL is *not* automatically a provider veto; follow its `RESULT` guidance.
      `# VERIFY`: SNP host was first proven on Ubuntu 26.04 (kernel 7.0); Rocky 10's kernel 6.12
      also carries SEV-SNP host support but is **unproven on this image** — this gate confirms it.
      (The OpenShift-node equivalent, `make verify-snp-host`, runs later in Phase 4 once RHCOS
      is installed — it proves the *RHCOS* kernel, which this rung-0 check does not.)

- [ ] **Lock the node's egress host-side, then VERIFY it bites** (the air gap must be *enforced*,
      not assumed — a silently-reachable internet would hide the VCEK-OfflineStore bug). Two
      separate controls, don't conflate them:
      - **Inbound** to the node is handled by the Latitude firewall (opt-in
        `-var enforce_latitude_firewall=true`; SSH/API/ingress from `admin_cidr` only).
      - **Egress** is locked **host-side with nftables**, allowing only the bastion's PRIVATE VLAN
        IP — Latitude firewall egress direction is undocumented, so do not rely on it. First bring
        up the node's VLAN L3 + mirror name (values from `terraform output` in Phase 1), then
        default-deny output except to the bastion's private IP:
      ```bash
      # VERIFY the node's VLAN parent interface (`ip -br link`); IDs/IPs come from the bastion outputs.
      ssh rocky@<node-ip> 'sudo ip link add link bond0 name bond0.<vid> type vlan id <vid>;
        sudo ip addr add 192.168.66.11/24 dev bond0.<vid>; sudo ip link set bond0.<vid> up;
        echo "192.168.66.10 mirror.rig.local" | sudo tee -a /etc/hosts'
      ssh rocky@<node-ip> 'sudo nft -f - <<EOF
      table inet airgap {
        chain output { type filter hook output priority 0; policy drop;
          ct state established,related accept
          oifname "lo" accept
          ip daddr 192.168.66.10 accept   # bastion PRIVATE VLAN IP only
        }
      }
      EOF'
      # probe — public egress must be DEAD, the private mirror must answer:
      ssh rocky@<node-ip> 'curl -m5 -sI https://quay.io >/dev/null && echo "EGRESS OPEN (bad)" || echo "EGRESS BLOCKED (good)"'
      ssh rocky@<node-ip> 'curl -m5 -skI https://mirror.rig.local:8443 >/dev/null && echo "MIRROR OK over VLAN"'
      ```
      (Pre-OpenShift: nft as above on the Rocky node. Post-install: apply the opt-in egress
      MachineConfig [`gitops/base/airgap-egress`](../../gitops/base/airgap-egress/) **after** the SNO
      is healthy — `oc apply -k gitops/base/airgap-egress` — it drops public egress while keeping all
      cluster traffic; do NOT add it to the install-time overlay.) Do not record the air gap as proven
      until public egress is BLOCKED **and** the bastion is reachable.

> **STOP-gate:** do not proceed unless `host-snp-check.sh` is green. A green result proves
> silicon + provider + (Rocky 10) kernel do SNP host; it does **not** yet prove RHCOS. If the
> script reports a genuine provider/firmware veto, the bare-metal decision is invalid for this
> node — fall back per design §6 rather than building on top.

---

## Phase 2 — Mirror the content (unattended, ~1–2 h — the bottleneck, cacheable)

Reference: [`scripts/mirror.sh`](../../scripts/mirror.sh),
[`install/imageset-config.yaml`](../../install/imageset-config.yaml),
[`install/README.md`](../../install/README.md). Runs on the bastion (has push access to the
mirror; the node does not run this).

- [ ] **`# VERIFY` the operator channels first** in `install/imageset-config.yaml` (NFD,
      cert-manager, OSC, Trustee all carry `# VERIFY`): confirm each against
      `oc-mirror list operators --catalog <idx> --package <name>` before mirroring 1–2 h of content.
- [ ] **Fill `MIRROR_REGISTRY` and mirror:**
      ```bash
      export MIRROR_REGISTRY=$(cd infra/latitude/bastion && terraform output -raw mirror_endpoint)
      make mirror                                           # -> scripts/mirror.sh mirror (oc-mirror --v2)
      ```
      This is the long pole. It is **cacheable** — the oc-mirror v2 workspace (`./mirror`)
      persists, so re-runs only fetch deltas. Mirror *before* you need the cluster.
- [ ] **Keep the generated cluster resources for post-install:** oc-mirror v2 emits
      IDMS/ITMS + CatalogSource under `./mirror/working-dir/cluster-resources/`. List them with
      `MIRROR_REGISTRY=… ./scripts/mirror.sh resources`. **Apply these only AFTER the cluster
      exists** (end of Phase 3) — the installer itself uses `install-config`'s
      `imageDigestSources`, not these objects:
      ```bash
      oc apply -f ./mirror/working-dir/cluster-resources/
      ```

> STOP-gate: mirror completed without errors; CatalogSource/IDMS YAML present in the workspace.

---

## Phase 3 — SNO install via Agent-based Installer (mixed; ~45 min build+boot, then unattended)

Reference: [`install/README.md`](../../install/README.md),
[`install/install-config.yaml.tmpl`](../../install/install-config.yaml.tmpl),
[`install/agent-config.yaml.tmpl`](../../install/agent-config.yaml.tmpl).

- [ ] **Fill the templates** (hands-on — every `# FILL` is host-specific; copy into a fresh
      assets dir so the `.tmpl` stays the source of truth):
      ```bash
      mkdir -p cluster-assets
      cp install/install-config.yaml.tmpl cluster-assets/install-config.yaml
      cp install/agent-config.yaml.tmpl  cluster-assets/agent-config.yaml
      ```
      Resolve from the node, tomorrow (install/README "Filling placeholders" + TODOs):
      - `install-config`: `baseDomain`/`metadata.name`, `machineNetwork` CIDR,
        `imageDigestSources` mirrors (= `MIRROR_REGISTRY` + the two repo paths oc-mirror wrote),
        `additionalTrustBundle` (mirror CA PEM), `pullSecret` (**mirror** creds, base64
        user:pass — not the RH cloud secret), `sshKey`.
      - `agent-config`: `rendezvousIP` (= the single node IP), `hostname`,
        `rootDeviceHints.deviceName` (`# FILL` `/dev/nvme0n1` vs `/dev/sda` — confirm with
        `lsblk` on the node), `interfaces[].macAddress` (real NIC MAC from IPMI/`ip link` —
        **never guess**), `networkConfig` static IP/gateway/DNS.
      - **VLAN to the mirror (RHCOS side of the air gap):** add an nmstate **VLAN interface**
        (parent bond + `vid` from `terraform output virtual_network_vid`) carrying the
        `node_vlan_ip` (`192.168.66.11`), and a host entry for the mirror name from
        `terraform output node_hosts_entry` (`192.168.66.10 mirror.rig.local`) so
        `imageDigestSources`/`additionalTrustBundle` resolve over the VLAN, not the public NIC.
        `# VERIFY` the bond/parent interface name on the node (hardware-bound).
- [ ] **Build the agent ISO** (unattended, ~5 min): `make agent-image` →
      `openshift-install --dir cluster-assets agent create image` → `cluster-assets/agent.x86_64.iso`.
      For a true air-gap, the `openshift-install` binary should ultimately come from
      `oc adm release extract --command=openshift-install` against the **mirrored** release so
      it matches the payload byte-for-byte (install/README step 3).
- [ ] **Boot the node** from the ISO (hands-on), one of:
      - **Latitude IPMI virtual media** — attach `agent.x86_64.iso` via the browser IPMI/KVM
        (`POST /servers/{id}/remote_access`), set one-time boot to virtual CD, reboot.
      - **Custom iPXE** — serve the ISO / kernel+initrd from the bastion and chain-load it.
- [ ] **Wait for completion** (unattended, ~30–45 min) from the admin host with line-of-sight
      to the node: `make install-wait` →
      `openshift-install --dir cluster-assets agent wait-for install-complete`.
      (Run `… wait-for bootstrap-complete` first if you want the staged checkpoint.) Kubeconfig
      + kubeadmin password land in `cluster-assets/auth/`.
- [ ] **Apply the post-install mirror resources** now that the cluster exists (Phase 2 last
      box): `oc apply -f ./mirror/working-dir/cluster-resources/`.

> STOP-gate: `install-complete` succeeded; `export KUBECONFIG=cluster-assets/auth/kubeconfig`
> and `oc get nodes` shows the single node `Ready`; CatalogSource from the mirror is present
> (`oc get catalogsource -n openshift-marketplace`).

---

## Phase 4 — Operators + KataConfig (mixed; ~30–45 min, includes a node reboot)

**Install order is load-bearing: NFD → cert-manager → OSC → Trustee** (design §3; enforced by
[`gitops/base/operators/subscriptions.yaml`](../../gitops/base/operators/subscriptions.yaml)).

- [ ] **RHCOS SNP host gate** (hands-on) — now that RHCOS is installed, prove the *RHCOS*
      kernel does SNP host (Phase 1 only proved the rung-0 OS):
      ```bash
      make verify-snp-host NODE=<node-name>     # -> scripts/verify-snp-host.sh
      ```
      Checks PSP SEV-SNP API, RMP table, no `Error: 0x3` (BIOS memory interleaving),
      `kvm_amd sev_snp = Y`, `/dev/sev`.

      > STOP-gate: do not apply GitOps until this is green.

- [ ] **Apply workers overlay** (unattended apply, then CSVs settle ~10–15 min):
      `make apply-sno` → `oc apply -k gitops/overlays/sno-workers`
      ([overlay](../../gitops/overlays/sno-workers/kustomization.yaml) = operators + kataconfig
      + workloads). Wait for all four CSVs `Succeeded`:
      ```bash
      oc get csv -A | grep -Ei 'nfd|cert-manager|sandboxed|trustee'
      ```
      `# VERIFY` the mirrored CatalogSource name / channels / CSVs in `subscriptions.yaml`
      against the mirror (`oc get packagemanifest <pkg> -n openshift-marketplace -o yaml`).
- [ ] **KataConfig reboots the node** (unattended, ~10–15 min) — applying
      [`kataconfig.yaml`](../../gitops/base/kataconfig/kataconfig.yaml) drives a MachineConfigPool
      rollout that **reboots the single node**. Watch the MCP, expect the node to cycle:
      ```bash
      oc get mcp -w
      ```
      `# VERIFY` the CoCo enablement mechanism against OSC 1.12: CoCo is enabled by the
      `osc-feature-gates` ConfigMap (`confidential: "true"`), NOT a KataConfig field —
      `oc explain kataconfig.spec` has no `enableConfidentialCompute` in 1.12.
- [ ] **Verify the RuntimeClasses** (the Phase-4 proof):
      ```bash
      oc get runtimeclass
      # expect:  kata   AND   kata-cc   (kata-cc handler resolves to kata-snp on SEV-SNP)
      ```

> STOP-gate: four CSVs `Succeeded`, node back `Ready` after the MCP reboot, and `kata` +
> `kata-cc` (handler `kata-snp`) RuntimeClasses present.

---

## Phase 5 — Air-gap attestation data (hands-on, hardware-bound, ~30–45 min)

Both pipelines run **on this hardware** and produce **environment-bound** data (design §4).
The operator ships nothing for these; VCEK automation is a **production sign-off gate**.

- [ ] **Stand up the rig Trustee** (unattended apply): `make apply-trustee` →
      `oc apply -k gitops/overlays/sno-trustee`
      ([overlay](../../gitops/overlays/sno-trustee/kustomization.yaml) = `base/trustee`). Out-of-band
      secrets per [`gitops/base/trustee/secret-stubs.example.yaml`](../../gitops/base/trustee/secret-stubs.example.yaml).
- [ ] **Collect VCEK certs into the OfflineStore** (hardware-bound):
      `make collect-vcek NODE=<node-name>` → [`scripts/collect-vcek.sh`](../../scripts/collect-vcek.sh).
      One secret **per socket**, keyed by **lowercase HWID** (`snphost show vcek-url` → download
      `.der` on a connected host → carry in). Generation-agnostic (dodges Trustee bug #591
      'Milan' hardcode). **Landmine:** an upper-case HWID silently falls through to a (here
      unreachable) KDS instead of the cache → attestation fails. Re-runnable for TCB refresh.
- [ ] **Generate RVPS reference values with Veritas** (hardware-bound):
      `make gen-rvps` → [`scripts/gen-rvps-veritas.sh`](../../scripts/gen-rvps-veritas.sh)
      (`coco-tools` pinned by digest, `veritas --tee snp --ocp-version <OCP_VERSION>`, one run
      per distinct socket/hardware config). On disconnected rigs, set `DEBUG_IMAGE` to a cached
      image for `oc debug node`; if Veritas's internal `oc adm release info` still reaches public
      `quay.io`, pass a temporary `VERITAS_OC_WRAPPER` that rewrites the release and
      `rhel-coreos-extensions` refs to the mirror.
- [ ] **Wire both into Trustee:** mount the VCEK secrets via
      `KbsConfig.spec.kbsLocalCertCacheSpec` (path
      `…/kds-store/vcek/<hwid>/vcek.der`) and merge the RVPS output into the
      `rvps-reference-values` ConfigMap referenced by
      [`gitops/base/trustee/kbsconfig.yaml`](../../gitops/base/trustee/kbsconfig.yaml). `# VERIFY`
      the CRD field names (`oc explain kbsconfig.spec` @ trustee-operator v1.1).

> STOP-gate: KBS pod restarts cleanly with the VCEK OfflineStore mounted and the RVPS
> reference values loaded (`oc logs` on the KBS pod shows no missing-cert / empty-RVPS errors).

---

## Phase 6 — Rungs a → b → c (hands-on, incremental, ~1–2 h)

A rung is **proven only when reproduced from these steps AND its negative test passes** (design
§5). Do them **in order** — do not skip ahead.
Rungs b/c are scaffolded in the repo but still need hardware proof. Follow Phase 6 of
[`install-execution-plan.md`](install-execution-plan.md) to build the image artifacts,
enable the KBS resources, and run the b/c happy + negative paths before checking the boxes
below.

- [ ] **Rung a — secret release.** Deploy the CoCo workload
      ([`gitops/base/workloads/rung-a-secret-pod.yaml`](../../gitops/base/workloads/rung-a-secret-pod.yaml),
      `runtimeClassName: kata-cc`). It init-gates on the in-CVM **CDH** at `127.0.0.1:8006`.
      - **Happy path:** the init container's
        `curl …/cdh/resource/default/attestation-status/status` returns success → workload runs.
      - **Negative test (the proof):** apply a **restrictive resource policy + wrong/empty
        RVPS** (or tamper initdata) → attestation **errors, secret withheld**, pod does not
        start. *(initdata `# FILL`s — `default_memory`, HOST_DATA — are per-overlay and
        environment-bound; keep the pod memory limit ≥ `default_memory` + 256 MiB or the host
        OOM-kills the CVM.)*
- [ ] **Rung b — encrypted image.**
      - **Happy path:** pod reaches `Running` (image key released after attestation).
      - **Negative test:** wrong measurement → key withheld → **pod won't start**.
      - **Implementation note:** use a digest-pinned encrypted image and KBS resource
        `image-key/rung-b`; do not count missing-key failure as the primary sign-off proof.
- [ ] **Rung c — signed image.**
      - **Happy path:** signed image pulls (mirror pull secret served as `regcred`, per
        `kbsconfig.yaml` `kbsSecretResources`).
      - **Negative test:** unsigned/tampered image → `image_security_policy` **rejects** the pull.
      - **Implementation note:** the signed policy must account for the app image and every
        infrastructure image pulled inside the CVM, including release/pause images.
- [ ] **Air-gap negative test (proves the cache is load-bearing):** temporarily remove the
      Trustee `vcek-*` Secrets, then rerun an otherwise happy rung-a request →
      **attestation fails** and the Secrets are restored. This proves the OfflineStore — not
      a silently reachable KDS — is doing the work.

> Denial-proof automation now exists at `make negative-test WHICH=all`
> ([Makefile](../../Makefile)); it renders the rung a/b/c negative manifests from the same
> apply scripts used by the happy paths. Treat it as a rig-side proof helper, not as proof
> by itself: it must run against the hardware cluster and fail closed for every rung.

> STOP-gate: every rung's happy path **and** negative test pass. Only then is a rung "proven".

---

## Phase 7 — Teardown (hands-on, ~5 min)

Reference: [`../../infra/latitude/README.md`](../../infra/latitude/README.md) (hourly billing —
destroy after each spike).

- [ ] **Destroy the node:** `cd infra/latitude && terraform destroy` (stops billing). Leaves the
      bastion (separate state) up so the mirror persists.
      - **Recovery gotcha:** the node module reads the bastion state on **every** op including
        `destroy`. If the bastion state is missing/moved (or you destroyed the bastion first), node
        `destroy` errors and you can't stop billing. Restore `infra/latitude/bastion/terraform.tfstate`
        (or run `terraform destroy -refresh=false`, or kill the server from the Latitude dashboard).
- [ ] **Note:** re-provisioning gives a **fresh node with default BIOS** — the Phase-1 SNP
      BIOS recipe must be re-applied every time. Provider+silicon are proven; the *settings*
      are not persistent across re-provision.

---

## Per-phase quick checklist

- [ ] **0 Prereqs** — `make tools`; `infra/latitude/bastion` (mirror-registry, persistent) + CA + internal git; RH pull secret.
- [ ] **1 Provision + rung-0** — bastion `apply` first, then node `apply`; SNP BIOS recipe; `host-snp-check.sh` green; egress-lockdown probe. **STOP.**
- [ ] **2 Mirror** — `# VERIFY` channels; `MIRROR_REGISTRY=… make mirror`; keep cluster-resources.
- [ ] **3 SNO install** — fill templates; `make agent-image`; boot (IPMI vmedia / iPXE);
      `make install-wait`; apply mirror cluster-resources.
- [ ] **4 Operators** — `make verify-snp-host` (STOP); `make apply-sno`; CSVs Succeeded; MCP
      reboot; `kata` + `kata-cc` RuntimeClasses.
- [ ] **5 Attestation data** — `make apply-trustee`; `make collect-vcek` (lowercase HWID);
      `make gen-rvps`; wire into KbsConfig + RVPS ConfigMap.
- [ ] **6 Rungs a→b→c** — each happy path **+** negative test; air-gap VCEK-pull negative test.
- [ ] **7 Teardown** — `terraform destroy`; BIOS resets on re-provision.
