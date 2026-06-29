# Air-gapped CoCo in-guest image pull — recipe + findings (2026-06-28)

The single hardest, least-documented part of disconnected CoCo on OSC 1.12: kata-cc pulls the
workload image **inside the confidential VM** (`image_guest_pull`), and the cluster's
ImageDigestMirrorSet does **NOT** apply in-guest. So the guest must be told — entirely via
**initdata** + **KBS-served resources** — how to reach the air-gapped mirror. This note records
the complete wiring proven reachable on the rig and the chain of blockers found.

> Status: ✅ **PROVEN END-TO-END 2026-06-29.** rung-a runs as `kata-cc` in the air-gapped cluster:
> SNP-attested via the VCEK OfflineStore (KDS blocked), secrets released by the in-cluster KBS, and
> the ubi9 image pulled from the bastion mirror over HTTPS (40MB layer, mirror nginx logged 200s).
> The full blocker chain and its resolution are below — every item is fixed, none open.

## The complete recipe (what disconnected CoCo guest pull requires)

1. **Initdata annotation key — `io.katacontainers.config.hypervisor.cc_init_data`** (NOT
   `io.confidentialcontainers.org/initdata`). Value = gzip+base64 of the initdata TOML. With the
   wrong key the kata shim never creates the initdata block device → the agent logs "Initdata
   device not found, skip" → `/run/confidential-containers/cdh/` is empty → image-rs uses defaults.
   Verified in-guest: with the correct key, `/run/confidential-containers/initdata/{aa,cdh}.toml`
   appear. (kata 3.25; `enable_annotations` must include `cc_init_data` — OSC default does.)

2. **CDH config in initdata `cdh.toml`** (extracted to `/run/confidential-containers/initdata/cdh.toml`):
   - `[kbc] url = http://kbs-service.trustee-operator-system.svc:8080` (in-cluster KBS; cluster DNS
     resolves `*.svc`, and the guest can reach it — confirmed `KBS_TCP_OK` from inside the CVM).
   - `[image] authenticated_registry_credentials_uri = "kbs:///default/credential/test"` and
     `image_security_policy_uri = "kbs:///default/security-policy/test"` — image-rs fetches the
     mirror auth + a permissive policy from KBS **after attestation**.
   - `[image.registry_config]` mirror remaps for **every** image the CVM pulls — INCLUDING the
     pause/sandbox image, which comes from the release payload:
       - `quay.io/openshift-release-dev/ocp-v4.0-art-dev` → `mirror.rig.local:8443/openshift/release`
       - `quay.io/openshift-release-dev/ocp-release`      → `mirror.rig.local:8443/openshift/release-images`
       - `registry.access.redhat.com/ubi9`               → `mirror.rig.local:8443/ubi9`
       (`insecure = true` on each mirror to skip the private-CA check, or supply the CA via
       `extra_root_certificates`.) The inline `[image.registry_config]` did NOT take effect in this
       OSC 1.12 CDH; the `registry_configuration_uri = kbs:///...` form is the one to rely on.

3. **KBS-served resources** (operator `KbsConfig.spec.kbsSecretResources`, secret `<name>` key
   `<key>` → `kbs:///default/<name>/<key>`):
   - `credential`/`test` = `{"auths":{"mirror.rig.local:8443":{"auth":"<base64 init:pw>"}}}`
   - `security-policy`/`test` = `{"default":[{"type":"insecureAcceptAnything"}]}`

4. **Cluster DNS must resolve the mirror name.** The guest uses cluster DNS (CoreDNS, 172.30.0.10),
   which does NOT know `mirror.rig.local` (that lives only in the bastion dnsmasq). Fix: point the
   `rig.local` zone at the bastion dnsmasq —
   `oc patch dns.operator/default --type=merge -p '{"spec":{"servers":[{"name":"riglocal","zones":["rig.local"],"forwardPlugin":{"upstreams":["192.168.66.10"]}}]}}'`.
   Verified: a normal pod resolves `mirror.rig.local → 192.168.66.10` and gets HTTP 200 from the
   mirror by name AND by IP. (Production env: use a name the cluster DNS already serves, or add this.)

5. **Timeouts.** Guest pull is bounded by `min(kubelet runtimeRequestTimeout, kata
   create_container_timeout)`. Defaults (kata 60s; kubelet 0s/effectively short) are too small for
   first-pull + SNP attestation. Raise both (kata `create_container_timeout=600`; kubelet
   `runtimeRequestTimeout: 20m` via KubeletConfig). On the rig these were set directly on the node.

## Chain of blockers found (in order) — ALL RESOLVED
1. Wrong initdata annotation key → initdata never delivered (CDH empty).            [FIXED → cc_init_data]
2. `create_container_timeout = 60` too short.                                       [FIXED → 600]
3. `mirror.rig.local` not resolvable by cluster DNS.                                [FIXED → CoreDNS forward]
4. Guest registry config missing the **pause/release** image remap (only had ubi9). [FIXED → full remap]
5. kubelet `runtimeRequestTimeout` caps guest pull.                                 [FIXED → 20m]
6. **kata-agent policy** from a minimal `policy.rego` denied `UpdateInterfaceRequest`
   → "Cannot start VM" (VM never finished network setup, before any pull).          [FIXED → omit policy.rego]
7. **KBS attestation policy** unreadable: operator subPath-mounts the `attestation-policy`
   ConfigMap key `default_cpu.rego`; ours was keyed `default.rego` → empty dir →
   coco-as "Failed to read … policy file: Is a directory" → /attest 401.            [FIXED → key default_cpu.rego]
8. Same ConfigMap content was `allow := true`, not an EAR `trust_claims` policy →
   broker can't appraise.                                                           [FIXED → EAR trust_claims]
9. `aa.toml` (attestation-agent KBS token config) is REQUIRED; dropping it stops the
   guest reaching KBS at all (CDH "ttrpc request error", no KBS traffic).           [FIXED → keep aa.toml]
10. Image **security-policy** as a bare `default` array → image-rs "Invalid image
    policy file".                                                                   [FIXED → add `transports`]
11. Inline `[image.registry_config]` in cdh.toml is IGNORED by OSC 1.12 CDH → image-rs
    tries the upstream registry (air-gap-dropped) → silent hang.                     [FIXED → registry_configuration_uri kbs://]
12. `insecure = true` made image-rs (oci-client 0.15) talk PLAIN HTTP to the TLS-only
    mirror :8443 → nginx 400 "plain HTTP sent to HTTPS port".                        [FIXED → drop insecure + extra_root_certificates (mirror CA) → HTTPS]

## End state (proven)
rung-a `1/1 Running`, `runtimeClassName: kata-cc`. KBS log for the successful run:
`POST /kbs/v0/attest 200` → `Verifier/endorsement check passed. tee=Snp` → `GET …/resource/default/
credential/test 200` + `…/security-policy/test 200`. Mirror nginx for the same run: `GET /v2/auth…
200`, `…/manifests/sha256:4ba3… 200`, `…/blobs/sha256:837b… 200 (40,689,274 bytes)` from
`oci-client/0.15.0`. The whole disconnected confidential-pull path works; remaining work
is rungs b/c (release/pause-image workloads — extend `registry-configuration` with the
`quay.io/openshift-release-dev/*` remaps) and the air-gap VCEK negative test. The b/c
implementation plan now lives in
[`../runbooks/rung-bc-completion-plan.md`](../runbooks/rung-bc-completion-plan.md).

## Diagnosis notes for next time (what was/wasn't useful)
- The host journal only ever shows the shim's CDH error string (e.g. "Invalid image policy file",
  "ttrpc request error"); the in-guest image-rs/CDH/AA detail does NOT forward to it.
- `kata-runtime exec` into the guest gives a `journalctl` dominated by systemd/D-Bus noise — not
  useful for image-rs. The high-signal vantage points were the **KBS pod log** (attest/resource
  status codes) and the **bastion mirror nginx/quay access log** (exact pull URLs + status codes).
  Watch those two, not the guest, to localize a guest-pull failure.
