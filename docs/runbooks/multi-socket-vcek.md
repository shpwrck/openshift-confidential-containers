# Multi-socket (2P) VCEK collection for the air-gap OfflineStore

**Who needs this:** anyone standing up CoCo on a **dual-socket (2P) SEV-SNP** box. Single-socket
nodes (the disposable rig) do **not** — `make collect-vcek NODE=<node>` fully covers them.

## Why the host-side path is not enough

Each physical SEV-SNP chip has its **own** PSP and its **own** VCEK (Versioned Chip Endorsement
Key), identified by a unique `CHIP_ID`. On a 2P board the two chips have **two distinct VCEKs**.
A confidential VM attests with the VCEK of **whichever socket it runs on**, so the Trustee
OfflineStore must hold **both** — a CVM scheduled on a socket whose VCEK is missing **fails
attestation**.

Host-side tools **cannot** enumerate per-socket VCEKs: `snphost show vcek-url` / `show identifier`
are answered by the board's single **master PSP**, and snphost has **no socket selector** — pinning
a host process's CPUs does *not* select a socket's PSP. So `collect-vcek.sh <node>` reliably
collects only the **master** socket's VCEK.

The **only** authoritative per-socket `CHIP_ID` is the one inside an **SNP attestation report**
(report offset `0x1A0`, 64 bytes) — which is exactly what Trustee keys the VCEK lookup on. A report
is produced by `snpguest report` **inside a confidential VM running on that socket**. This runbook
collects each socket's report, then fetches that socket's VCEK from it.

> **Validation status.** The `CHIP_ID`→VCEK mechanism, the report offset parse, the KDS fetch, and
> the stable secret naming were validated on the single-socket rig (the report's `CHIP_ID` equals
> the chip's hwid; the fetched VCEK's public key matches the cached one). The **two-distinct-sockets
> enumeration** can only be proven on real 2P silicon — that is this procedure's on-hardware step.

## Prerequisites

- `snpguest` on a KDS-connected admin host (it ships in the `coco-tools` image — run it via that
  container, or copy the binary out).
- The `coco-tools` image must be **guest-pullable** in your air gap (present in the mirror; the
  guest's registry-configuration KBS resource must rewrite `quay.io/openshift_sandboxed_containers`
  to your mirror, same as the rung-a images). If it isn't, bake `snpguest` into any image that
  already guest-pulls.

## Procedure

### 1. Collect the master socket (as usual)

```bash
make collect-vcek NODE=<node>       # or: scripts/collect-vcek.sh <node>
```

This writes `vcek-bundle/<master-hwid>/vcek.der`, creates its secret, and prints a NOTE that the
node has >1 socket with the exact next steps below. It does **not** fail — the master VCEK is valid.

### 2. Get each other socket's SNP report

You need a report from a CVM on **each** socket. Two ways:

**(a) Oversample (robust, no pinning needed).** Deploy several probe pods; the scheduler spreads
them across sockets, so with enough samples you hit every socket. Collect all their `CHIP_ID`s and
dedupe — no fragile NUMA pinning required.

```yaml
# probe-vcek.yaml — a kata-cc pod that prints its socket's CHIP_ID and emits report.bin.
apiVersion: v1
kind: Pod
metadata: { name: vcek-probe, namespace: default }
spec:
  runtimeClassName: kata-cc            # confidential; gets /dev/sev-guest inside the CVM
  restartPolicy: Never
  containers:
    - name: probe
      image: <mirror>/openshift_sandboxed_containers/coco-tools@sha256:<digest>
      command: ["/bin/sh","-c"]
      args:
        - |
          set -e
          /tools/snpguest report /tmp/report.bin -r
          echo "CHIP_ID=$(dd if=/tmp/report.bin bs=1 skip=416 count=64 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
          sleep 3600      # keep alive so you can `oc cp` the report out
```

The pod needs the **same initdata** (mirror registry config + CA) as rung-a so the guest can pull
`coco-tools`; render it the way `scripts/apply-rung-a.sh` does for its pod.

Deploy N of these (e.g. `N = 2 × sockets`), read each `CHIP_ID` from its log, and copy out the
reports for the **distinct** `CHIP_ID`s you haven't seen yet:

```bash
for i in $(seq 1 4); do oc get pod vcek-probe-$i -o jsonpath='{.metadata.name}: '; oc logs vcek-probe-$i | grep CHIP_ID; done
oc cp default/vcek-probe-2:/tmp/report.bin ./report-socketB.bin     # a report whose CHIP_ID != master
```

**(b) Pin (deterministic).** If your platform reliably honors it, pin the probe pod to the target
socket's NUMA node (Guaranteed QoS + integer CPU requests + Topology Manager `single-numa-node`, or
an explicit `cpuset`). Confirm it landed where intended by comparing its `CHIP_ID` to the master's —
**same `CHIP_ID` means it landed on the master socket**, so try again.

### 3. Fetch each non-master socket's VCEK from its report

On the KDS-connected admin host (with `snpguest`):

```bash
scripts/collect-vcek.sh --from-report ./report-socketB.bin      # add more reports as args
# EPYC model hint if snpguest needs it: PROCESSOR=genoa scripts/collect-vcek.sh --from-report ...
```

This reads the report's `CHIP_ID`, fetches **that socket's** VCEK (snpguest uses the report's own
`reported_tcb`, so per-socket TCB differences are honored), and stages it at
`vcek-bundle/<hwid>/vcek.der`.

### 4. Seed the secrets and wire KbsConfig

Carry `vcek-bundle/` into the air gap and re-run the collect (or the Trustee apply). Secrets are
named **`vcek-snp-<hwid-prefix>-<hash>`** (an hwid prefix plus a hash of the full CHIP_ID — stable,
never renumbered when the chip set changes, and collision-free across sockets), and
`scripts/apply-trustee.sh` renders one `KbsConfig.spec.kbsLocalCertCacheSpec.secrets`
entry per hwid, mounting each at `…/kds-store/vcek/<hwid>/vcek.der`.

```bash
scripts/collect-vcek.sh <node>      # (re)creates secrets from every vcek-bundle/<hwid>/vcek.der
make deploy-trustee                 # re-renders KbsConfig with one entry per socket
```

### 5. Verify (the on-hardware proof)

- `vcek-bundle/` has **one dir per socket**, each with a **distinct** hwid and a `vcek.der`.
- `oc -n trustee-operator-system get secret | grep vcek-snp-` shows **one secret per socket**.
- `KbsConfig` `kbsLocalCertCacheSpec.secrets` has **one entry per socket**.
- Schedule a rung-a pod (or your workload) **on each socket** and confirm each **attests
  successfully** — that is the real proof both sockets' VCEKs are load-bearing. If a CVM on one
  socket fails attestation while the other succeeds, that socket's VCEK is missing or wrong.

## TCB refresh

A firmware/microcode update changes a chip's `reported_tcb`, which changes its VCEK — but **not**
its `CHIP_ID`. So a TCB refresh reuses the same `vcek-bundle/<hwid>/` dir and secret: re-run this
procedure and the refreshed cert updates the right secret in place (re-fetching also gives a new
cert *validity window* for the same VCEK key — harmless).

If you **replace** a socket/chip (a *new* `CHIP_ID`), delete the old `vcek-bundle/<old-hwid>/` dir
and its `vcek-snp-*` secret — otherwise `collect-vcek.sh` re-seeds it and `apply-trustee.sh` renders
a stale (unused) `KbsConfig` entry for a chip that is no longer present.
