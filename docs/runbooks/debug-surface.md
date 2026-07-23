# Debug surface — every vantage point, log level, and location

> Claims marked ✅ have been verified on live hardware; `# VERIFY` marks the remaining
> guesses. Where a behavior differs by operator version, the row says so inline.
>
> **Where commands run** (unless a block says otherwise): `oc`/`gh`/repo scripts → the
> **admin host** (the bastion in a disconnected env — wherever the kubeconfig and repo
> checkout live). Bare `journalctl`/`crictl`/`nft`/`dmesg`/toml edits → **on the node**
> (get there via §4's access doors). §6 → **inside the CVM**. Registry-access-log greps →
> **on the registry host** (§8).

A CoCo failure leaves evidence on **four machines**: the cluster/host (RHCOS node), the guest
CVM, the Trustee pod, and the registry (Artifactory / bastion mirror). No single log shows the
whole story — the host journal only ever gets the shim's terse CDH error string, and the guest
journal is systemd noise around the one line you need. This runbook maps **all** of the vantage
points, how to turn each component's logging up, and where each log lives — then gives the
triage for the headline symptom: **Trustee run is clean but the pod never runs**.

Companions (don't duplicate — open alongside):
- [`rung-kbs-guest-debug.md`](rung-kbs-guest-debug.md) — the interactive catch-the-CVM +
  `kata-runtime exec` procedure (needs a human TTY).
- [`failure-modes.md`](failure-modes.md) — symptom → cause → fix by install phase.
- [`../notes/airgap-coco-guest-pull.md`](../notes/airgap-coco-guest-pull.md) — the complete
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
`runtimeRequestTimeout`)** — recommended 600 s / 20 m. On defaults (60 s) a healthy first pull
dies as `DeadlineExceeded` before stage 9 completes.

## 2. Triangulate before you tunnel

The two **high-signal** ends (see the diagnosis notes in `airgap-coco-guest-pull.md`)
are the **KBS pod log** (stages 7–8, with status codes) and the **registry
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

"Every URI" = the `kbs:///default/<name>/<key>` references the initdata's `cdh.toml` declares
the guest will fetch after attestation. For an in-guest-pull workload the typical set is
three — miss any one and the pull cannot proceed:

| cdh.toml field | typical URI | what the guest gets |
|---|---|---|
| `authenticated_registry_credentials_uri` | `kbs:///default/credential/test` | registry auth (dockerconfig) |
| `image_security_policy_uri` | `kbs:///default/security-policy/test` | image acceptance policy |
| `registry_configuration_uri` | `kbs:///default/registry-configuration/test` | the mirror remap (registries.conf) |

(Workload-specific secrets — e.g. rung-a's `sample` — add more rows; the decode command above
is always the source of truth for *this* pod.)

**Branch 0 — the release 401s (Trustee 1.2.x). ✅** Before reading the
registry log, check the KBS log for `GET /kbs/v0/resource/... 401` right after a 200 attest,
with `TokenVerifierError … Cannot verify token`. On RH Trustee 1.2.x with no persistent token
signer, the builtin AS signs its EAR token with an **ephemeral key** (AS startup log: `No
Token Signer key in config file`) and the verifier rejects it — attestation "clean", every
resource withheld, in-guest just `ttrpc request error`. Fix: an **EC** (P-256) signer under
`[attestation_service.attestation_token_broker] signer = {key_path, cert_path}` with the same
cert in `[attestation_token] trusted_certs_paths` (`insecure_key = true` does NOT bypass this
build's check; an RSA signer crashes the AS: `expecting an ec key`). Full write-up: issue #65.
Check:
```bash
oc -n trustee-operator-system logs deploy/trustee-deployment --since=1h \
  | grep -E 'resource/.* 401|No Token Signer key|Cannot verify token'
```
Any match = this branch.

Then branch on the **registry log** (End C):

1. **No requests from the guest at all** ✅ → the pull never started or went to the *upstream*
   registry name (air-gap-drops it → silent hang until `DeadlineExceeded`). Signature:
   KBS shows all three resources 200 — with a **smaller-than-healthy
   `registry-configuration` response** (the byte count in the KBS log line is a remap-present
   tell — e.g. 935 B with the remap vs 475 B without) — and CoreDNS at `Trace` shows the guest
   **successfully resolving the upstream name** before the TCP connect blackholes. A good DNS
   answer proves nothing about the registry path: the air-gap drop is at TCP. Causes, most
   likely first:
   - `registry-configuration` never fetched (see above) — inline `[image.registry_config]` is
     **silently ignored** on OSC 1.12; only `registry_configuration_uri = "kbs:///…"` works.
   - The remap is missing the image actually being pulled — remember the **pause/sandbox image
     is pulled in-guest too** (release-payload ref, e.g. `quay.io/openshift-release-dev/…`), not
     just the app image. If the *sandbox* pull fails the CVM dies before the app is attempted.
   - The registry hostname doesn't resolve **in-guest** (guest uses cluster CoreDNS, not the
     node's resolv.conf) — see the DNS probe in §6 and `dns.operator` in §7.

   Check (three 200s + registry silence = this branch):
   ```bash
   oc -n trustee-operator-system logs deploy/trustee-deployment --since=30m | grep 'resource/default'
   # registry access log, same window: zero lines from UA oci-client/ = pull never arrived
   # optional (needs CoreDNS Trace, §7): did the guest try the UPSTREAM name?
   oc -n openshift-dns logs ds/dns-default -c dns --since=30m | grep <upstream-registry-host>
   ```
2. **Requests, but 401/403** ✅ → the `credential` KBS resource is keyed to the wrong host (must
   be the Artifactory `host:port` exactly as it appears in the *remapped* ref, not the upstream
   name), or the dockerconfig entry has no inline base64 `auth` (credHelpers/identitytoken
   don't work in-guest). Fingerprint: the registry's `/v2/auth` line goes **anonymous**
   (user field `- -` where a healthy pull shows the mirror user, and a smaller token response —
   e.g. 846 B vs 1003 B on quay), then `manifests/… 401`. Caution: a stale KBS pod can
   serve the *old* credential for one round — restart KBS and re-run before trusting a
   "still works" result.

   Check (registry access log, same window):
   ```bash
   grep '/v2/auth' <access-log> | tail -3    # empty/missing user field = anonymous
   grep 'manifests' <access-log> | tail -3   # 401s right after = this branch
   ```
3. **Requests, TLS errors client-side** (registry log shows handshake resets or nothing after
   `/v2/`) → Artifactory CA missing from `extra_root_certificates`, or `insecure = true` set
   (makes image-rs speak plain HTTP to a TLS port → 400).

   Check (the initdata itself carries both misconfigurations):
   ```bash
   scripts/encode-initdata.sh decode <initdata.b64> | grep -cE 'BEGIN CERTIFICATE'  # 0 = no CA
   scripts/encode-initdata.sh decode <initdata.b64> | grep -n 'insecure'            # any hit = suspect
   ```
4. **Manifests + blobs all 200, pod still not Running** → the pull succeeded; the failure is
   *after* stage 9:
   - Timeout budget exhausted mid-unpack — raise both timeouts (§7) and retry; compare blob
     bytes/time in the registry log against the budget. Confirm the knobs are still in effect
     first (§7's verify command) — an MCO rollout silently reverts node-direct edits.
   - QEMU OOM-killed ✅ — SNP pins **all** guest RAM at boot; `limits.memory` must be ≥ the
     `default_memory` annotation + ~256 Mi. On the node: `dmesg | grep -i oom`. Observed
     signature: `oom-kill:constraint=CONSTRAINT_MEMCG … task=qemu-kvm` in the pod's
     `kubepods-burstable` memcg within ~25 s of scheduling, while pod events still show only
     `Scheduled`/`AddedInterface` — the host journal leads the events by minutes. (Note: the
     Gatekeeper CoCo memory-floor mutation did NOT correct an undersized explicit limit —
     don't assume admission saves you.)
   - Guest tmpfs exhausted mid-unpack — in-guest pull unpacks under `/run` inside the CVM, a
     tmpfs bounded by guest RAM: the registry log shows every blob 200 yet the pod dies;
     in-guest `df -h /run` is full / journal shows ENOSPC or a guest-side OOM → raise
     `…hypervisor.default_memory` (and the pod memory limit with it, per the OOM rule). A
     small test image can mask this — real workload images are far bigger.
   - kata-agent policy denial — if a `policy.rego` rides in the initdata, it can deny
     `CreateContainerRequest`/`UpdateInterfaceRequest` ("Cannot start VM"). This repo's
     baseline omits policy.rego entirely (blocker #6 in the airgap notes).
5. **`ttrpc request error` in events** → not a pull problem at all: the guest components have
   no `aa.toml` (or died) so the shim's call into the guest fails. Re-check the initdata
   annotation key is exactly `io.katacontainers.config.hypervisor.cc_init_data` and that
   `aa.toml` is present in the TOML (dropping it kills all KBS traffic).

   Check (on the node — did the annotation cross the kubelet→CRI-O hop, with aa.toml inside?):
   ```bash
   SB=$(crictl pods --name <pod> -q); crictl inspectp "$SB" \
     | jq -r '.info.runtimeSpec.annotations["io.katacontainers.config.hypervisor.cc_init_data"] // "MISSING"' \
     | { read v; [ "$v" = MISSING ] && echo MISSING || echo "$v" | base64 -d | gunzip | grep -c aa.toml; }
   ```

If the branches above don't resolve it, bracket further **in-guest** (§6): initdata present? →
KBS/registry reachable via `/dev/tcp`? → `/run/image-rs` growing? → journal grep.

## 4. Host vantage (RHCOS node)

Access — two doors:

```bash
oc debug node/<node>      # interactive TTY (required for kata-runtime exec later)
chroot /host
# or, fallback when the apiserver is down: ssh core@<node-ip> from the bastion/admin host
# no TTY needed for journals (automation / scarce access):
oc adm node-logs <node> -u crio -u kubelet --since='-1h' > node.log   # VERIFY --since format on this oc
oc adm node-logs <node> --grep=kata                                    # VERIFY --grep availability
# if node-logs balks (flag missing / empty output): fall back to the interactive door above
# (oc debug node -> chroot /host -> journalctl), or ssh core@<node-ip> and journalctl there
```

Discovery — find the runtime pieces before you read them (paths vary by OSC build; do not
guess):

```bash
oc get runtimeclass kata-cc -o jsonpath='{.handler}{"\n"}'      # (admin host) want kata-qemu-snp / kata-snp
# — everything below runs ON THE NODE —
crio config 2>/dev/null | grep -B2 -A10 'runtimes.kata'         # runtime_path + runtime_config_path per handler
find /etc/kata-containers /usr/share/kata-containers /usr/share/defaults/kata-containers \
     -name '*.toml' 2>/dev/null                                  # the effective configuration.toml candidates
kata-runtime env 2>/dev/null | head -40                          # effective config as the runtime sees it  # VERIFY flag name on OSC 1.12
# if kata-runtime env doesn't exist on this build: the crio-config + find lines above are the
# authoritative path — read the runtime_config_path toml directly
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
# RHCOS-native alternative (tcpdump needs toolbox; ss is always present) — sample for
# stuck SYNs to a blackholed registry; the burst windows are short, so loop it:
while :; do nsenter --net="$NETNS" ss -tn state syn-sent | tail -n +2; sleep 2; done
```

Early-boot console (stage 4 failures — the agent never comes up, so `kata-runtime exec` can't
work): the guest console socket lives under the sandbox's `/run/vc/vm/<sid>/` dir
(`console.sock`); attach with `socat -,raw,echo=0 unix-connect:/run/vc/vm/$SB/console.sock` to
see kernel output. `# VERIFY` the socket name/path on OSC 1.12 — if it isn't there, list the
sandbox dir (`ls /run/vc/vm/$SB/`) for the actual socket name; if the console attaches but
stays silent, guest debug is off (§7) — fall back to `journalctl -t kata` for whatever the
shim relays.

**socat/tcpdump/strace are NOT on RHCOS** — run `toolbox` from the chroot to get them (air
gap: mirror `registry.redhat.io/rhel9/support-tools` and pin `REGISTRY`/`IMAGE` in
`/root/.toolboxrc`). From the same toolbox, `sos report --all-logs` produces the host bundle
Red Hat support asks for alongside must-gather.

Must-gather — use the **OSC** image, not generic:

```bash
# match the tag to your installed OSC version:
oc adm must-gather --image=registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:<osc-version>
```

## 5. Operator / control-plane vantage

```bash
oc -n openshift-sandboxed-containers-operator logs deploy/controller-manager --since=1h   # KataConfig reconcile  # VERIFY deploy name
oc -n trustee-operator-system logs deploy/trustee-operator-controller-manager --since=1h  # KbsConfig reconcile ✅
# if a deploy name doesn't resolve: discover it — oc get deploy -n <ns>
oc get kataconfig cluster-kataconfig -o yaml | grep -A10 status:
oc get mcp; oc get events -n openshift-sandboxed-containers-operator --sort-by=.lastTimestamp | tail
```

Use these when the *plumbing* is suspect (RuntimeClass wrong/missing, KataConfig stuck, KBS
deployment not reconciling) rather than a single pod failing.

**Empty events ≠ nothing happened.** An operator can be taking consequential actions that
never reach `oc get events` — e.g. the Trustee 1.2.1 operator's ConfigMap-migration
deletions are event-RBAC-broken (`cannot patch events.k8s.io`), so its deletes are visible
ONLY as DEBUG lines in the controller log (✅). When a resource you applied keeps
disappearing or a reconcile stalls with clean events, read the controller log before
concluding the operator is idle.

The OSC **monitor DaemonSet** (kata-monitor) is a live "how many CVMs exist, are the shims
healthy" view needing no guest access:
`oc -n openshift-sandboxed-containers-operator logs ds/openshift-sandboxed-containers-monitor --since=1h`
(DS name checked against OSC 1.13.0), plus Prometheus metrics
`kata_monitor_running_shim_count` / `kata_shim_*` during a pod attempt
`# VERIFY metric names`.

## 6. Guest vantage (inside the CVM)

Full interactive procedure — deploy, catch, exec: [`rung-kbs-guest-debug.md`](rung-kbs-guest-debug.md).
Precondition: `debug_console_enabled = true` in the kata agent config (§7). `kata-runtime exec
<sandbox-id>` needs a **real TTY** (`oc debug node` gives one; non-interactive automation
cannot). If exec fails with a connection/console error, the debug console is off — enabling it
(§7) needs no re-measure, but the pod must be recreated; until then your only guest windows
are the console socket (§4) and whatever the shim relays to `journalctl -t kata`. If the CVM
dies too fast to catch, use the stable-CVM fallback in that runbook (briefly lift egress so
the pause pull succeeds and the sandbox stays up).

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

When the probe commands themselves misbehave (minimal rootfs — these are the known modes):

- `(exec 3<>/dev/tcp/...)` **hangs** instead of failing — there is no timeout builtin; a hang
  >5 s IS the failure result (unreachable/blackholed). Ctrl-C and treat as FAIL.
- `journalctl` absent on the guest image → `dmesg | tail -50` for kernel-adjacent errors;
  agent/CDH detail is then only available via the shim relay (`journalctl -t kata` on the host).
- `systemctl` absent (non-systemd guest) → `ps -ef` and grep for the agent/CDH/AA process
  names instead of units.

Interpretation table for the probes: "What each result means" in `rung-kbs-guest-debug.md`.

## 7. Turning logging up — every knob

**⚠️ Measurement warning before touching anything.** Two traps:
1. Any **initdata** edit changes the measured HOST_DATA → under the restrictive rung-B policy
   the secret release goes **403** — attest itself still succeeds; the policy withholds the
   resource (KBS log: `measurement mismatch`; HTTP 403 — the rung-B negative test exercises exactly this) —
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
| kata full debug (runtime/hypervisor/agent) | host+guest | shim journal grows agent+QEMU output | `configuration.toml`: `enable_debug = true` under `[runtime]`, `[hypervisor.qemu]`, `[agent.kata]` — ⚠️ the `[agent.kata]` half injects `agent.log=debug` into the kernel cmdline = **measured** (see warning); the other two are host-side and safe. Find the file via §4 discovery; quick = edit on the node, durable = MachineConfig (raw /etc edits risk MCO drift — cf. `make repair-sno-baseline`) |
| guest kernel + kata-agent verbosity | guest | shim journal / console.sock | `kernel_params = "agent.log=debug"` (+`agent.debug_console` for console shell) in the toml's `[hypervisor.qemu]` — **measured**, see warning |
| debug console | guest | interactive via `kata-runtime exec` | `debug_console_enabled = true` under `[agent.kata]` |
| AA / CDH / api-server-rest | guest | guest journal (info) | `RUST_LOG` is baked into the guest image's unit files — raising it means a **custom guest image + re-measure**; in practice read the guest journal instead `# VERIFY no initdata-level override exists in OSC 1.12` |
| image-rs | guest (inside CDH's pull service) | its lines appear in the guest journal greps | follows CDH |
| KBS / AS / RVPS (all-in-one) | Trustee pod | `oc -n trustee-operator-system logs deploy/trustee-deployment` (info) | `KbsConfig` env: `KbsEnvVars: {RUST_LOG: debug}` — capital K: it is the one CRD spec property that is *not* lower-camelCase (✅ on trustee-operator 1.2.1: accepted, pod restarts with debug active); same field already used for the proxy |
| CRI-O | host | `journalctl -u crio` (info) | operator way: `KataConfig spec.logLevel: debug` — **version-sensitive**: on OSC 1.12.0 a privileged daemonset writes the drop-in + `systemctl reload crio` (no reboot); on **OSC 1.13.0** (✅) it renders a **MachineConfig → drain + REBOOT** and writes a nested `[crio] [crio.runtime] log_level` drop-in. Check `oc get mcp` before assuming it's free. Manual: `99-debug.conf` with a `[crio.runtime]` table + `systemctl reload crio` — a key under bare `[crio]` is **silently ignored** |
| kubelet | host | `journalctl -u kubelet` | KubeletConfig verbosity — rarely worth it; the timeout knob matters more (below) |
| CoreDNS (in-guest name resolution) | cluster | `oc logs -n openshift-dns ds/dns-default -c dns` | `oc patch dns.operator/default --type=merge -p '{"spec":{"logLevel":"Trace"}}'` — `Trace` (`class all`) logs **every** query, great for "does the guest resolve Artifactory"; `Debug` logs only denials/errors, so a *successful* lookup never appears at Debug. ✅ guest queries visible by pod IP, incl. the search-domain NXDOMAIN then the bare-name answer |
| Trustee operator / OSC operator | cluster | §5 | deployment `--v` args if ever needed `# VERIFY` |
| Artifactory | customer registry | §8 | customer-side; request log is on by default |

**The two timeout knobs** (not logging, but they decide whether you ever *see* the failure —
and they are also your **debug window**: a hung pull attempt lives for the full budget, and the
kubelet retries CreateContainer after each expiry, so a generously-budgeted CVM stays up and
exec-able (§6) across attempts instead of vanishing after 60 s):
kata `create_container_timeout = 600` in the toml + kubelet `runtimeRequestTimeout: 20m` (via
KubeletConfig — durable; direct node edits work but revert on MCO rollouts). Defaults kill a
healthy first pull. Before
trusting the budget, verify the knobs are still in effect — an MCO rollout silently reverts
node-direct edits back to the 60 s defaults, which then mimics the headline symptom exactly:

```bash
# on the node:
grep -r create_container_timeout /etc/kata-containers /usr/share/kata-containers 2>/dev/null
grep runtimeRequestTimeout /etc/kubernetes/kubelet.conf
```

Per-pod debug alternative: kata honors `io.katacontainers.config.*` pod annotations for some
hypervisor fields (the repo already uses `…hypervisor.default_memory`), but each key must be in
the toml's `enable_annotations` allowlist — check before relying on e.g.
`…hypervisor.kernel_params` `# VERIFY OSC 1.12 allowlist`. Check on the node:

```bash
grep -A3 enable_annotations /etc/kata-containers/kata-snp/configuration.toml
```

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
  reachable inside the air gap (e.g. served by the bastion).
- **Two independent proxies** — Trustee pod (`KbsEnvVars`) and CVM (`aa.toml`/`cdh.toml`
  proxy keys); neither inherits the cluster proxy. In a proxied customer env, an unset guest
  proxy looks like a registry hang.
- **Gatekeeper** guards CoCo pod memory (`gitops/base/gatekeeper/`) — an admission denial means
  the pod object never exists; it's in `oc get events`, not in any node log. (✅ caveat:
  it did not correct an *undersized explicit* limit — verify, don't assume.)
- **The air gap is not reboot-stable** (issue #66): the `inet airgap` nft table can
  be silently flushed by another service after the oneshot unit already reported success —
  unit status is NOT proof. After ANY reboot or nftables/OVN churn:
  `nft list table inet airgap` must list the table AND `curl -m5 https://quay.io` from the
  node must fail. A silently-open air gap invalidates every OfflineStore "proof" after it.
- **Attestation smoke without a workload**: fetch the `attestation-status` resource path with
  the KBS client from a debug pod to separate "attestation broken" from "image pull broken"
  without burning a 10-minute pod timeout `# VERIFY client availability in the mirrored images`.
  If no KBS client image is available: `curl -si http://<kbs-svc>:8080/kbs/v0/resource/default/sample/secret`
  from any pod still proves KBS is up and *enforcing* (expect 401 — anonymous must be denied);
  a full release proof then needs a real attested guest (the smallest CoCo pod you have).
- **401 vs 403 from KBS** — the sharpest triage fork, but read it per *endpoint*:
  - `POST /attest` **401** = verifier rejected the evidence (bad VCEK chain, wrong cert — the
    attestation itself).
  - `GET /resource/…` **401** = the attestation *token* wasn't accepted (expired, or the
    verifier has no trust path to the token signer — see §3 branch 0). Attest can be 200 and
    resources still 401.
  - `GET /resource/…` **403** = token fine, **policy** refused the release (measurement
    mismatch, RVPS gap).
  The negative tests rely on exactly this distinction — so should your triage.

## 10. Log-collection kit (grab everything once, analyze offline)

When live access is scarce (customer env), collect everything in one visit. Fill the three
variables, run the block, and take the directory home — the set answers every branch in §3
without a second visit. (Plus, from the registry side: the Artifactory/mirror request log for
the same time window — §8.)

```bash
POD=<pod> NS=<ns> NODE=<node> OUT=coco-debug-$(date +%Y%m%d-%H%M) && mkdir -p "$OUT"
oc describe pod "$POD" -n "$NS"                                   > "$OUT/pod-describe.txt"
oc get events -n "$NS" --sort-by=.lastTimestamp                   > "$OUT/events.txt"
oc -n trustee-operator-system logs deploy/trustee-deployment --all-containers \
                                                                   > "$OUT/kbs.log" 2>&1
oc -n trustee-operator-system logs deploy/trustee-operator-controller-manager \
                                                                   > "$OUT/trustee-operator.log" 2>&1
oc -n openshift-sandboxed-containers-operator logs deploy/controller-manager \
                                                                   > "$OUT/osc-operator.log" 2>&1   # VERIFY deploy name (§5)
oc adm node-logs "$NODE" -u crio -u kubelet                       > "$OUT/node-crio-kubelet.log" 2>&1
oc get kataconfig,kbsconfig,runtimeclass -A -o yaml               > "$OUT/crs.yaml"
oc get pod "$POD" -n "$NS" \
  -o jsonpath='{.metadata.annotations.io\.katacontainers\.config\.hypervisor\.cc_init_data}' \
  | base64 -d | gunzip                                            > "$OUT/initdata-decoded.toml"
oc adm must-gather --image=registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:<osc-version> \
  --dest-dir="$OUT/must-gather"
```

If a line fails, don't stop: every file is independently useful, and §§4–5 name the fallback
for each source (node-logs → debug-node journalctl; deploy names → `oc get deploy -n <ns>`).
