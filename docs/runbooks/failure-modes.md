# Failure-mode playbook — disconnected SNO + CoCo bring-up

Pre-mortem for tomorrow. Ordered by phase; each entry is **symptom → likely cause →
fast diagnostic → fix**. Read the "Top 7" first — those are the ones I'd bet actually bite.

> Primary signal for almost everything CoCo: **`oc describe pod` + `oc get events`**, not
> container logs (CoCo pods often never reach Running). KBS rejections: `oc logs -n
> trustee-operator-system -l app=kbs`.

---

## Top 7 most likely to bite (and why)

1. **`# VERIFY` field names reject on `oc apply`.** Our `gitops/base/**` manifests were authored
   from the onboarding guide, **not validated against live CRDs**. The KataConfig CoCo field and
   the `KbsConfig` field names (incl. `kbsLocalCertCacheSpec`) are guesses. → `oc apply` errors
   "unknown field". **Fix:** `oc explain kataconfig.spec` / `oc explain kbsconfig.spec`, correct,
   re-render. *Do this the moment OSC/Trustee CSVs are installed, before trusting the overlays.*
2. **CatalogSource not READY (disconnected).** No mirrored catalog index = zero operators install.
3. **NFD doesn't label the node `SEV_SNP`.** No label → KataConfig builds the wrong handler →
   `kata-cc` handler ≠ `kata-snp`. (We *proved* SNP host works, so a missing label = NFD/config,
   not silicon.)
4. **Egress firewall too tight / DNS wrong.** SNO needs the mirror reachable **and**
   `api`/`api-int`/`*.apps` resolvable. First disconnected attempt almost always trips one of these.
5. **Agent install never starts** — wrong root device (`nvme0n1` vs `sda`), wrong MAC, or
   rendezvous IP mismatch in `agent-config.yaml`.
6. **QEMU OOM-killed at pod launch.** SNP pins *all* guest RAM at boot; if `limits.memory` <
   CVM RAM annotation, the host OOM-killer nukes QEMU in seconds → `DeadlineExceeded`.
7. **VCEK silent fail** — uppercase HWID dir, or KDS left in `vcek_sources` so it "works" by
   reaching the internet that won't exist on the production side. Attestation fails for the wrong reason.

---

## Phase 1 — Provision + SNP host gate
*(we have lived experience here — see docs/notes/latitude-snp-bringup.md)*

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| SSH `Connection timed out` after deploy | cloud-init still booting / first SNP boot slow | `nc -vz <ip> 22`; API `status` | wait; retry loop (we have one) |
| SSH `Permission denied (publickey)` as root | native image user is **`ubuntu`**, not root | `ssh ubuntu@<ip>` | use `ubuntu` + `sudo` |
| `host-snp-check` FAIL, "memory encryption not enabled by BIOS" | SMEE off | dmesg grep SEV | BIOS: SMEE=Enabled |
| `SEV-SNP disabled` / "IOMMU SNP feature not enabled" | **`SEV-SNP Support`=Auto** (North Bridge page) | dmesg grep snp | set `SEV-SNP Support`=Enabled (Auto≠on) |
| PSP `Error: 0x3` | Memory Interleaving on | dmesg grep 0x3 | BIOS: disable interleaving |
| BIOS reset after re-provision | new physical machine | — | **don't re-provision mid-phase**; keep the node |
| IPMI console rejects creds | token/password rotated | — | re-`POST /remote_access` (URL+user+pass together) |

## Phase 2 — Mirror (oc-mirror v2)  *— the slow one; fail here = hours lost*

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| `oc-mirror` 401/403 pulling from registry.redhat.io | RH pull secret missing/expired in `~/.docker/config.json` | `podman login registry.redhat.io` | refresh pull secret (console.redhat.com) |
| Push to mirror fails TLS / x509 | mirror registry CA not trusted | `curl -v https://$MIRROR` | add mirror CA to host trust + `additionalTrustBundle` |
| Out of disk mid-mirror | tens of GB per release+catalogs | `df -h` | size the bastion ≥ ~200 GB; resume oc-mirror |
| Operators present but **CatalogSource not READY** post-install | IDMS/ITMS + CatalogSource from oc-mirror output not applied, or index image not pushed | `oc get catalogsource -A`; `oc -n openshift-marketplace logs <cs-pod>` | apply the `cluster-resources/` oc-mirror emitted; confirm index image mirrored |
| Subscription stuck `UpgradePending`/no CSV | wrong channel, or catalog missing the package | `oc get packagemanifest -n openshift-marketplace`; `oc describe sub` | fix channel (`# VERIFY`), confirm package mirrored |

## Phase 3 — SNO Agent-based install

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| Node boots installer but **install never progresses** | wrong rootDeviceHints (nvme vs sda) | console; `lsblk` | fix `agent-config` deviceName |
| Agent never forms cluster | rendezvousIP ≠ the node's actual IP / MAC wrong | console logs; `ip a` | correct rendezvousIP + interface MAC |
| `wait-for` hangs at bootstrap | DNS: `api-int.<cluster>.<base>` unresolvable | from node `dig api-int...` | add DNS records (or static /etc/hosts pattern for SNO) |
| Stuck pulling release images | egress firewall blocks the **mirror**, or `imageDigestSources` wrong | node → `curl https://$MIRROR/v2/` | open egress to bastion; fix mirror map + trust bundle |
| Cert/auth errors during install | clock skew | `timedatectl` | NTP to a reachable (bastion) source; SNP attestation also needs good time |
| IPMI virtual-media won't boot ISO | Latitude media mount quirk | IPMI console | fall back to custom iPXE (`agent create pxe-files`) |

## Phase 4 — Operators + KataConfig

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| `oc apply -k` rejects fields | the `# VERIFY` CRD field guesses | `oc explain <kind>.spec` | correct field names, re-render |
| No node has `SEV_SNP` label | NFD not done / not running | guide's NFD jq query; `oc get pods -n openshift-nfd` | wait 2-3 min; check NFD; **don't** hand-label (masks fault) |
| `kata-cc` handler is not `kata-snp` | KataConfig applied before NFD labeled | `oc get runtimeclass kata-cc -o jsonpath='{.handler}'` | re-apply KataConfig after labels exist |
| MCP `kata-oc` stuck UPDATING / reboot loop | SNO: the single node reboots itself for the MachineConfig | `oc get mcp`; `oc describe mcp kata-oc` | wait it out; SNO has no spare node, so it's a self-reboot |
| Trustee controller CrashLoopBackOff | default memory limit too low | `oc -n trustee-operator-system describe pod` | raise/remove the Deployment memory limit |

## Phase 5 — Air-gap attestation data (VCEK + RVPS)

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| Attestation fails, OfflineStore "miss" | **uppercase HWID** dir | check secret keys vs `kds-store/vcek/<hwid>` | lowercase the HWID |
| "works" on rig but will fail at customer | `KDS` left in `vcek_sources` (reached the internet) | grep kbs-config.toml | remove `{type=KDS}` for true offline test |
| VCEK rejected / wrong chain | ARK/ASK not present or wrong gen (Milan vs Genoa #591) | KBS logs | supply ARK/ASK; confirm Trustee gen mapping |
| Veritas RVPS mismatch | initdata changed after Veritas run | KBS logs "measurement mismatch" | re-run Veritas with current initdata |
| Veritas reaches public `quay.io` in a disconnected rig | Baremetal Veritas shells out to `oc adm release info` for a hard-coded public OCP release tag | Veritas logs `unable to read image quay.io/openshift-release-dev/ocp-release:<version>-x86_64` | set `OCP_VERSION`, use a cached `DEBUG_IMAGE` for node mode, pass mirror-capable auth, and supply a short-lived `VERITAS_OC_WRAPPER` that rewrites release/extension refs to the mirror; keep separate release-mirror provenance because the wrapper may bypass upstream `--verify` |

## Phase 6 — Rungs a→b→c

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| Pod `DeadlineExceeded`, QEMU exits in seconds | **OOM**: `limits.memory` < CVM RAM annotation | `dmesg | grep oom` on node | `limits.memory` ≥ annotation + 512Mi |
| `DeadlineExceeded`, AA can't reach KBS | wrong KBS URL/cert in initdata | decode initdata; test ClusterIP insecure first | fix `aa.toml`/`cdh.toml` URL; passthrough vs re-encrypt cert |
| `certificate verify failed` | wrong cert pinned (passthrough vs re-encrypt) | — | pin the right cert per route type |
| Image pull "Not authorized" / cert error in-guest | regcred missing, or registry CA not in initdata | events | add `regcred` (name **without dots**), CA as **separate** array elements |
| attestation-status returns `error` after restricted policy | empty/mismatched RVPS | KBS logs | run Veritas, apply reference values |
| Negative test *passes* (secret released when it shouldn't) | policy not actually enforcing | — | this is a real finding — policy/RVPS not wired; fix before sign-off |

## Cross-cutting (bite at any phase)
- **Time sync** — attestation tokens + TLS certs fail on skew. Keep NTP reachable (bastion).
- **Two independent proxies** — Trustee pod (`KbsEnvVars`) and CVM (`aa.toml` + `cdh.toml`);
  neither inherits cluster proxy. Easy to set one and forget the other.
- **must-gather** — use the **OSC** image, not generic (`registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:1.12.0`).
- **Disconnected = nothing reaches the internet** — if something "works," confirm it isn't
  quietly using egress that won't exist in production.

## Fast triage commands
```bash
oc describe pod <p> | grep -A30 Events:          # always start here
oc get events -n <ns> --sort-by=.lastTimestamp | tail -20
oc get mcp; oc get csv -A | grep -Ev Succeeded   # operator/MCO health
oc get catalogsource -A; oc get packagemanifest -n openshift-marketplace | grep -E 'sandboxed|trustee|nfd|cert-manager'
oc get runtimeclass; oc get nodes -o json | jq '.items[].metadata.labels' | grep -i sev_snp
oc logs -n trustee-operator-system -l app=kbs --tail=100 | grep -Ei 'warn|error|deny|reject|measurement'
```
