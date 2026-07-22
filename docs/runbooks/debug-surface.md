# Debug surface — every vantage point, log level, and location

A CoCo failure leaves evidence on **four machines**: the cluster/host (RHCOS node), the guest
CVM, the Trustee pod, and the registry (Artifactory / bastion mirror). No single log shows the
whole story — the host journal only ever gets the shim's terse CDH error string, and the guest
journal is systemd noise around the one line you need. This runbook maps **all** of the vantage
points, how to turn each component's logging up, and where each log lives — then gives the
triage for the live customer symptom: **Trustee run is clean but the pod never runs**.

Companions (don't duplicate — open alongside):
- [`rung-kbs-guest-debug.md`](rung-kbs-guest-debug.md) — the interactive catch-the-CVM +
  `kata-runtime exec` procedure (needs a human TTY).
- [`failure-modes.md`](failure-modes.md) — symptom → cause → fix by install phase.
- [`../notes/airgap-coco-guest-pull.md`](../notes/airgap-coco-guest-pull.md) — the proven
  guest-pull wiring + the full blocker chain (the "what was/wasn't useful" notes at the end
  are the origin of the triangulation method below).
- [`../templates/customer-artifactory/README.md`](../templates/customer-artifactory/README.md)
  — the Artifactory bundle + its load-bearing gotcha checklist.

---

## 1. The pipeline — where each stage leaves evidence

A `kata-cc` pod start crosses these stages **in order**. Localize the failure to a stage first;
each stage names the log that proves it ran.

| # | Stage | Component (where it runs) | Evidence that it ran / failed |
|---|---|---|---|
| 1 | Admission + schedule | apiserver, Gatekeeper (cluster) | `oc get events` — Gatekeeper denial = pod never created |
| 2 | Sandbox create request | kubelet → CRI-O (host) | `journalctl -u crio` / `-u kubelet` on the node |
| 3 | CVM launch (QEMU + SNP) | containerd-shim-kata-v2 → QEMU (host) | `journalctl -t kata`; `ps -ef \| grep qemu` shows `sev-snp-guest`; `dmesg` for OOM/`KVM`/RMP errors |
| 4 | Guest boot + kata-agent up | kernel, kata-agent (guest) | console output (§4) is the only direct pre-agent witness; failure = `DeadlineExceeded` with stage 7 never appearing in the KBS log |
| 5 | Initdata delivered | shim → agent (host→guest) | in-guest `/run/confidential-containers/initdata/{aa,cdh}.toml` exist; wrong annotation key → agent logs "Initdata device not found, skip" |
| 6 | Network setup | agent + kata-agent policy (guest) | agent policy denial (`UpdateInterfaceRequest`) → "Cannot start VM" in events/shim log |
| 7 | Attestation | AA → KBS (guest → Trustee) | KBS log: `POST /kbs/v0/attest 200` + `Verifier/endorsement check passed. tee=Snp` (401 = verifier fail) |
| 8 | Resource release | CDH → KBS (guest → Trustee) | KBS log: `GET …/resource/default/<name>/<key> 200` — **one per URI referenced in cdh.toml** (403 = policy denies) |
| 9 | In-guest image pull (pause **and** app) | CDH/image-rs → registry (guest → Artifactory) | registry request log: `/v2/` auth → manifests → blobs from UA `oci-client/…`; **zero requests = remap not applied** |
| 10 | Unpack + container create | agent (guest) | events `Created`/`Started`; timeout here = pull finished but budget exhausted |

Literal event strings → stages: `FailedCreatePodSandBox … context deadline exceeded` = the
stage 3–9 timeout umbrella (localize with the other logs); `… Cannot start VM` = stage 6;
`… ttrpc request error` = stage 4/5 (guest components dead); `CreateContainerError` = stage 10.
**Guest-pull means the kubelet never pulls** — `ErrImagePull`/`ImagePullBackOff` will NEVER
appear even when the pull *is* the failure; their absence proves nothing.

The whole run is bounded by **min(kata `create_container_timeout`, kubelet
`runtimeRequestTimeout`)** — rig values 600 s / 20 m. On defaults (60 s) a healthy first pull
dies as `DeadlineExceeded` before stage 9 completes.

## 2. Triangulate before you tunnel

Proven on the rig (see the diagnosis notes in `airgap-coco-guest-pull.md`): the two
**high-signal** ends are the **KBS pod log** (stages 7–8, with status codes) and the **registry
access log** (stage 9, with exact URLs + codes). The guest is the noisiest and hardest vantage —
go there only after the two ends have bracketed the failure to stages 4–6 or 9-in-guest.

```bash
# End A — cluster symptom (always start here; CoCo pods usually die before logs exist)
oc describe pod <p> | grep -A30 Events:
oc get events -n <ns> --sort-by=.lastTimestamp | tail -20

# End B — Trustee (attestation + release, with HTTP codes)
oc -n trustee-operator-system logs deploy/trustee-deployment --since=30m \
  | grep -iE 'attest|resource|verifier|40[13]|error|deny'

# End C — registry (did the guest ever ask for the image?)
#   rig:      bastion nginx/quay access log
#   customer: Artifactory request log — see §8
```

Correlate the **timestamps** of the three. The failure lives in the gap between the last thing
that happened and the first thing that didn't.

## 3. Playbook — "Trustee is clean but the pod never runs"

"Clean" must mean: `attest 200` **and** a `200` for **every** `kbs:///…` URI the initdata
references. Verify that first — a run that attests fine but never fetches
`registry-configuration` is *not* clean, it is the smoking gun.

```bash
# What SHOULD be fetched (the URIs in the pod's initdata):
scripts/encode-initdata.sh decode <initdata.b64> | grep -E 'kbs:///'
# What WAS fetched:
oc -n trustee-operator-system logs deploy/trustee-deployment | grep 'resource/default'
```

Then branch on the **registry log** (End C):

1. **No requests from the guest at all** → the pull never started or went to the *upstream*
   registry name (air-gap-drops it → silent hang until `DeadlineExceeded`). Causes, most likely
   first:
   - `registry-configuration` never fetched (see above) — inline `[image.registry_config]` is
     **silently ignored** on OSC 1.12; only `registry_configuration_uri = "kbs:///…"` works.
   - The remap is missing the image actually being pulled — remember the **pause/sandbox image
     is pulled in-guest too** (release-payload ref, e.g. `quay.io/openshift-release-dev/…`), not
     just the app image. If the *sandbox* pull fails the CVM dies before the app is attempted.
   - The registry hostname doesn't resolve **in-guest** (guest uses cluster CoreDNS, not the
     node's resolv.conf) — see the DNS probe in §6 and `dns.operator` in §7.
2. **Requests, but 401/403** → the `credential` KBS resource is keyed to the wrong host (must
   be the Artifactory `host:port` exactly as it appears in the *remapped* ref, not the upstream
   name), or the dockerconfig entry has no inline base64 `auth` (credHelpers/identitytoken
   don't work in-guest).
3. **Requests, TLS errors client-side** (registry log shows handshake resets or nothing after
   `/v2/`) → Artifactory CA missing from `extra_root_certificates`, or `insecure = true` set
   (makes image-rs speak plain HTTP to a TLS port → 400).
4. **Manifests + blobs all 200, pod still not Running** → the pull succeeded; the failure is
   *after* stage 9:
   - Timeout budget exhausted mid-unpack — raise both timeouts (§7) and retry; compare blob
     bytes/time in the registry log against the budget. Confirm the knobs are still in effect
     first (§7's verify command) — an MCO rollout silently reverts node-direct edits.
   - QEMU OOM-killed — SNP pins **all** guest RAM at boot; `limits.memory` must be ≥ the
     `default_memory` annotation + ~256 Mi. On the node: `dmesg | grep -i oom`.
   - Guest tmpfs exhausted mid-unpack — in-guest pull unpacks under `/run` inside the CVM, a
     tmpfs bounded by guest RAM: the registry log shows every blob 200 yet the pod dies;
     in-guest `df -h /run` is full / journal shows ENOSPC or a guest-side OOM → raise
     `…hypervisor.default_memory` (and the pod memory limit with it, per the OOM rule). The
     rig only ever proved a 40 MB layer — real customer images are far bigger.
   - kata-agent policy denial — if a `policy.rego` rides in the initdata, it can deny
     `CreateContainerRequest`/`UpdateInterfaceRequest` ("Cannot start VM"). The rig omits
     policy.rego entirely (blocker #6 in the airgap notes).
5. **`ttrpc request error` in events** → not a pull problem at all: the guest components have
   no `aa.toml` (or died) so the shim's call into the guest fails. Re-check the initdata
   annotation key is exactly `io.katacontainers.config.hypervisor.cc_init_data` and that
   `aa.toml` is present in the TOML (dropping it kills all KBS traffic).

If the branches above don't resolve it, bracket further **in-guest** (§6): initdata present? →
KBS/registry reachable via `/dev/tcp`? → `/run/image-rs` growing? → journal grep.

## 4. Host vantage (RHCOS node)

Access — two doors:

```bash
oc debug node/<node>      # interactive TTY (required for kata-runtime exec later)
chroot /host
# or, rig fallback with a broken apiserver: ssh core@<node-ip> from the bastion
# no TTY needed for journals (automation / scarce access):
oc adm node-logs <node> -u crio -u kubelet --since='-1h' > node.log   # VERIFY --since format on this oc
oc adm node-logs <node> --grep=kata                                    # VERIFY --grep availability
```

Discovery — find the runtime pieces before you read them (paths vary by OSC build; do not
guess):

```bash
oc get runtimeclass kata-cc -o jsonpath='{.handler}{"\n"}'      # want kata-qemu-snp / kata-snp
crio config 2>/dev/null | grep -B2 -A10 'runtimes.kata'         # runtime_path + runtime_config_path per handler
find /etc/kata-containers /usr/share/kata-containers /usr/share/defaults/kata-containers \
     -name '*.toml' 2>/dev/null                                  # the effective configuration.toml candidates
kata-runtime env 2>/dev/null | head -40                          # effective config as the runtime sees it  # VERIFY flag name on OSC 1.12
```

Logs on the host:

```bash
journalctl -t kata --since -1h            # the kata shim/runtime — CDH error strings surface HERE
journalctl -u crio --since -1h            # CRI-O's view (sandbox create/timeout)
journalctl -u kubelet --since -1h         # kubelet's view (runtimeRequestTimeout expiry)
journalctl -k | grep -iE 'sev|snp|rmp|ccp'  # SNP host/firmware trouble
journalctl -k | grep -iE 'sev(-es|-snp)?.*asid' # ASID pool: each CVM burns one; note the boot-time
                                          # range vs `ps -ef | grep -c sev-snp-guest` — launch fails
                                          # ONLY when N CVMs already run = pool exhausted (BIOS
                                          # SEV-ES/SNP ASID split)
dmesg | grep -i oom                       # QEMU OOM kill (the DeadlineExceeded-in-seconds case)
```

> The host journal shows only what the shim relays — e.g. `Invalid image policy file`,
> `ttrpc request error`. The *reason* stays in-guest. Treat host-journal CDH strings as stage
> markers, not root causes.

Sandbox lifecycle + the running CVM:

```bash
crictl pods; crictl ps -a                  # CRI view incl. dead sandboxes
SB=$(crictl pods --name <pod> -q)          # deterministic sandbox id (replaces the ps race for live pods)
crictl inspectp "$SB" | jq '.status.state,
  (.info.runtimeSpec.annotations["io.katacontainers.config.hypervisor.cc_init_data"] // "MISSING" | .[:60])'
                                           # CRI-O's recorded state/error + proof the initdata
                                           # annotation crossed the kubelet→CRI-O hop
ls /run/vc/sbs/ /run/vc/vm/ 2>/dev/null    # per-sandbox state dirs (sandbox id = dir name)
ps -ef | grep -E 'qemu|virtiofsd' | grep -v grep   # the CVM itself: look for -object sev-snp-guest, -m <RAM>
# catch a short-lived sandbox id the moment it appears:
while :; do SB=$(ps -ef | grep -oE 'sandbox-[a-f0-9]{64}' | sed 's/sandbox-//' | head -1); \
  [ -n "$SB" ] && break; sleep 1; done; echo "SB=$SB"
```

Host-side CVM network trace — the CVM's traffic traverses the pod's host-side netns, so a
tcpdump there shows the guest's DNS queries, TCP SYNs, and TLS handshakes **without touching
the guest or any measured config**. It separates "guest never tried" from "SYN blackholed"
from "TLS reset" while you wait for the registry-side log:

```bash
NETNS=$(crictl inspectp "$SB" | jq -r '.info.runtimeSpec.linux.namespaces[] | select(.type=="network").path')
nsenter --net="$NETNS" tcpdump -nn 'port 53 or port 443 or port 8080 or port 8443'
```

Early-boot console (stage 4 failures — the agent never comes up, so `kata-runtime exec` can't
work): the guest console socket lives under the sandbox's `/run/vc/vm/<sid>/` dir
(`console.sock`); attach with `socat -,raw,echo=0 unix-connect:/run/vc/vm/$SB/console.sock` to
see kernel output. `# VERIFY` the socket name/path on OSC 1.12 — and note the console is only
chatty when guest debug is on (§7).

**socat/tcpdump/strace are NOT on RHCOS** — run `toolbox` from the chroot to get them (air
gap: mirror `registry.redhat.io/rhel9/support-tools` and pin `REGISTRY`/`IMAGE` in
`/root/.toolboxrc`). From the same toolbox, `sos report --all-logs` produces the host bundle
Red Hat support asks for alongside must-gather.

Must-gather — use the **OSC** image, not generic:

```bash
oc adm must-gather --image=registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:1.12.0
```

## 5. Operator / control-plane vantage

```bash
oc -n openshift-sandboxed-containers-operator logs deploy/controller-manager --since=1h   # KataConfig reconcile  # VERIFY deploy name
oc -n trustee-operator-system logs deploy/trustee-operator-controller-manager --since=1h  # KbsConfig reconcile   # VERIFY deploy name
oc get kataconfig cluster-kataconfig -o yaml | grep -A10 status:
oc get mcp; oc get events -n openshift-sandboxed-containers-operator --sort-by=.lastTimestamp | tail
```

Use these when the *plumbing* is suspect (RuntimeClass wrong/missing, KataConfig stuck, KBS
deployment not reconciling) rather than a single pod failing.

The OSC **monitor DaemonSet** (kata-monitor) is a live "how many CVMs exist, are the shims
healthy" view needing no guest access:
`oc -n openshift-sandboxed-containers-operator logs ds/openshift-sandboxed-containers-monitor --since=1h`,
plus Prometheus metrics `kata_monitor_running_shim_count` / `kata_shim_*` during a pod attempt
`# VERIFY DS name/metric names on OSC 1.12`.

## 6. Guest vantage (inside the CVM)

Full interactive procedure — deploy, catch, exec: [`rung-kbs-guest-debug.md`](rung-kbs-guest-debug.md).
Precondition: `debug_console_enabled = true` in the kata agent config (§7) — already set on the
rig. `kata-runtime exec <sandbox-id>` needs a **real TTY** (`oc debug node` gives one;
non-interactive automation cannot). If the CVM dies too fast, use the stable-CVM fallback in
that runbook (briefly lift egress so the pause pull succeeds and the sandbox stays up).

The in-guest map — what exists where (minimal rootfs: bash builtins work; `curl`/`ip`/`getent`
usually absent):

| Path / command | Meaning |
|---|---|
| `/run/confidential-containers/initdata/{aa,cdh}.toml` | initdata was delivered (missing = wrong annotation key) |
| `/run/confidential-containers/cdh/` | credentials land here **after** successful attestation (empty + journal attestation error = stage 7 fail) |
| `/run/image-rs/`, `/run/kata-containers/` | pull progress — growing = stage 9 under way |
| `df -h /run` | pull unpacks into guest-RAM tmpfs — full = ENOSPC/guest-OOM *after* a registry log full of 200s (§3.4) |
| `cat /etc/resolv.conf` | the DNS the guest actually received (expect cluster CoreDNS `172.30.0.10`; anything else explains a name-only failure) |
| `date -u` (vs bastion) | guest clock skew breaks attestation tokens + TLS even when the *node* clock is clean |
| `(exec 3<>/dev/tcp/<host>/<port>)` | reachability probe (KBS svc, Artifactory) without curl |
| `journalctl -b --no-pager \| grep -iE 'image-rs\|confidential-data-hub\|attestation\|kbs\|pull\|registry\|error\|denied\|x509\|connect'` | the actual error, buried in systemd noise |
| `systemctl list-units \| grep -iE 'kata\|confidential\|attestation'` | which guest components even exist/run on this image |

Interpretation table for the probes: "What each result means" in `rung-kbs-guest-debug.md`.

## 7. Turning logging up — every knob

**⚠️ Measurement warning before touching anything.** Two traps:
1. Any **initdata** edit changes the measured HOST_DATA → under the restrictive rung-B policy
   the secret release goes **403** — attest itself still succeeds; the policy withholds the
   resource (KBS log: `measurement mismatch`; proven as HTTP 403 by the rung-B negative test) —
   until you regenerate RVPS (`make gen-rvps`; install-guide §7.4 "freeze initdata").
2. Any **guest kernel cmdline** change (e.g. `agent.log=debug` via `kernel_params`) changes the
   SNP launch digest (QEMU measured direct boot, `kernel-hashes=on`) → if your RVPS policy pins
   `snp_launch_measurement`, same 403 (secret withheld).

So: debug with the **permissive** policy first, or regenerate reference values after flipping a
measured knob. A "debugging change" that breaks secret release looks exactly like the bug
you're chasing — and per the §9 rule it shows as **403**, not 401.

| Component | Where it runs | Log location (default level) | How to raise |
|---|---|---|---|
| kata runtime + shim | host | `journalctl -t kata` (info) | `enable_debug = true` under `[runtime]` (next row) — there is **no operator knob** for the shim stream; `KataConfig spec.logLevel` tunes CRI-O, not this |
| kata full debug (runtime/hypervisor/agent) | host+guest | shim journal grows agent+QEMU output | `configuration.toml`: `enable_debug = true` under `[runtime]`, `[hypervisor.qemu]`, `[agent.kata]` — find the file via §4 discovery; rig = edit on node, durable = MachineConfig (raw /etc edits risk MCO drift — cf. `make repair-sno-baseline`) |
| guest kernel + kata-agent verbosity | guest | shim journal / console.sock | `kernel_params = "agent.log=debug"` (+`agent.debug_console` for console shell) in the toml's `[hypervisor.qemu]` — **measured**, see warning |
| debug console | guest | interactive via `kata-runtime exec` | `debug_console_enabled = true` under `[agent.kata]` (already on, on the rig) |
| AA / CDH / api-server-rest | guest | guest journal (info) | `RUST_LOG` is baked into the guest image's unit files — raising it means a **custom guest image + re-measure**; in practice read the guest journal instead `# VERIFY no initdata-level override exists in OSC 1.12` |
| image-rs | guest (inside CDH's pull service) | its lines appear in the guest journal greps | follows CDH |
| KBS / AS / RVPS (all-in-one) | Trustee pod | `oc -n trustee-operator-system logs deploy/trustee-deployment` (info) | `KbsConfig` env: `KbsEnvVars: {RUST_LOG: debug}` — capital K: it is the one CRD spec property that is *not* lower-camelCase (`oc explain kbsconfig.spec` shows it); same field already used for the proxy |
| CRI-O | host | `journalctl -u crio` (info) | operator way: `KataConfig spec.logLevel: debug` — a privileged daemonset writes `/etc/crio/crio.conf.d/01-ctrcfg-logLevel` (`[crio.runtime] log_level`) then `systemctl reload crio`; **no MachineConfig, no reboot**, applies live (SNO included). Manual: `99-debug.conf` with the same `[crio.runtime]` table + `systemctl reload crio` — a key under bare `[crio]` is **silently ignored** |
| kubelet | host | `journalctl -u kubelet` | KubeletConfig verbosity — rarely worth it; the timeout knob matters more (below) |
| CoreDNS (in-guest name resolution) | cluster | `oc logs -n openshift-dns ds/dns-default -c dns` | `oc patch dns.operator/default --type=merge -p '{"spec":{"logLevel":"Trace"}}'` — `Trace` (`class all`) logs **every** query, great for "does the guest resolve Artifactory"; `Debug` logs only denials/errors, so a *successful* lookup never appears at Debug |
| Trustee operator / OSC operator | cluster | §5 | deployment `--v` args if ever needed `# VERIFY` |
| Artifactory | customer registry | §8 | customer-side; request log is on by default |

**The two timeout knobs** (not logging, but they decide whether you ever *see* the failure):
kata `create_container_timeout = 600` in the toml + kubelet `runtimeRequestTimeout: 20m` (via
KubeletConfig; rig set both directly on the node). Defaults kill a healthy first pull. Before
trusting the budget, verify the knobs are still in effect — an MCO rollout silently reverts
node-direct edits back to the 60 s defaults, which then mimics the live symptom exactly:

```bash
grep -r create_container_timeout /etc/kata-containers /usr/share/kata-containers 2>/dev/null
grep runtimeRequestTimeout /etc/kubernetes/kubelet.conf
```

Per-pod debug alternative: kata honors `io.katacontainers.config.*` pod annotations for some
hypervisor fields (the repo already uses `…hypervisor.default_memory`), but each key must be in
the toml's `enable_annotations` allowlist — check before relying on e.g.
`…hypervisor.kernel_params` `# VERIFY OSC 1.12 allowlist`.

## 8. Registry vantage (Artifactory)

The registry access log is the **single best witness** for stage 9 — it proved the rig's pull
end-to-end (exact manifests/blobs URLs, byte counts, UA `oci-client/0.15.0`). Ask the customer
for, in order of preference:

1. The access log of any **reverse proxy / LB in front of Artifactory** (nginx/HAProxy) —
   closest analogue of the rig's mirror nginx log.
2. `artifactory-request.log` (`$JFROG_HOME/artifactory/var/log/`) — every request with method,
   path, status, user, bytes. Grep for the repo path your remap targets and for `401|403|404`.

What a **clean** in-guest pull looks like (repo-path shapes vary with Artifactory's docker
access method — port vs subdomain vs `/artifactory/api/docker/<repo>/v2/…`):

```
GET /v2/                      → 401 (challenge) then token fetch → 200
GET …/v2/<repo>/manifests/sha256:… → 200
GET …/v2/<repo>/blobs/sha256:…     → 200 (big byte counts)
```

Read it against §3: nothing at all → remap/DNS; 401s → credential keying; 404 on manifests →
remap points at the wrong repo path (or the digest isn't in Artifactory); truncated blob
transfers → timeout budget.

Also confirm the guest's *token* requests hit Artifactory's auth endpoint — a `credential`
keyed to the wrong host shows up as anonymous token requests followed by 401s on manifests.

Two **Artifactory-only** behaviors that mimic §3 branches (enterprise features — ask the
customer): an **Xray "block download" policy** returns 403 on a correctly-authenticated blob
GET — looks exactly like branch 2 credential keying, so check the repo's Xray policies before
chasing auth; and a **remote/virtual repo** proxying an upstream registry hangs or 404/504s on
cache misses inside the air gap — looks like branch 1, so confirm the remap targets a **local**
repo.

## 9. Cross-cutting checks

- **Time skew** breaks attestation tokens *and* TLS: `timedatectl` on the node; NTP must be
  reachable inside the air gap (bastion serves it on the rig).
- **Two independent proxies** — Trustee pod (`KbsEnvVars`) and CVM (`aa.toml`/`cdh.toml`
  proxy keys); neither inherits the cluster proxy. In a proxied customer env, an unset guest
  proxy looks like a registry hang.
- **Gatekeeper** guards CoCo pod memory (`gitops/base/gatekeeper/`) — an admission denial means
  the pod object never exists; it's in `oc get events`, not in any node log.
- **Attestation smoke without a workload**: fetch the `attestation-status` resource path with
  the KBS client from a debug pod to separate "attestation broken" from "image pull broken"
  without burning a 10-minute pod timeout `# VERIFY client availability in the mirrored images`.
- **401 vs 403 from KBS**: 401 = verifier/evidence rejected (attestation itself); 403 = policy
  refused the resource (attested fine, denied release). The negative tests rely on exactly
  this distinction — so should your triage.

## 10. Log-collection kit (grab everything once, analyze offline)

When live access is scarce (customer env), collect these in one visit — each is one command
from §§2–8: `oc describe pod` + events; Trustee pod log (full, not grepped); OSC + Trustee
operator logs; `journalctl -t kata`, `-u crio`, `-u kubelet`, `dmesg` from the node (no TTY
needed — `oc adm node-logs`, §4);
`oc get kataconfig,kbsconfig,runtimeclass -o yaml`; the *decoded* initdata actually on the pod;
the KBS resource list (`oc get kbsconfig -o yaml` → `kbsSecretResources`); Artifactory request
log for the time window; `oc adm must-gather` with the OSC image. That set answers every branch
in §3 without a second visit.
