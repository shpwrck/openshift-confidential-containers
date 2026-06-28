# Air-gapped CoCo in-guest image pull — recipe + findings (2026-06-28)

The single hardest, least-documented part of disconnected CoCo on OSC 1.12: kata-cc pulls the
workload image **inside the confidential VM** (`image_guest_pull`), and the cluster's
ImageDigestMirrorSet does **NOT** apply in-guest. So the guest must be told — entirely via
**initdata** + **KBS-served resources** — how to reach the air-gapped mirror. This note records
the complete wiring proven reachable on the rig and the chain of blockers found.

> Status: every layer below was found and fixed/validated in sequence. End state: the whole chain
> is wired and **all endpoints are reachable from the guest**, but kata-cc sandbox creation still
> does not complete the guest pull. The final guest-internal diagnosis (image-rs/CDH/AA logs)
> needs an **interactive** `kata-runtime exec` TTY or OSC support — see "Remaining" below.

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
   mirror by name AND by IP. (Customer env: use a name the cluster DNS already serves, or add this.)

5. **Timeouts.** Guest pull is bounded by `min(kubelet runtimeRequestTimeout, kata
   create_container_timeout)`. Defaults (kata 60s; kubelet 0s/effectively short) are too small for
   first-pull + SNP attestation. Raise both (kata `create_container_timeout=600`; kubelet
   `runtimeRequestTimeout: 20m` via KubeletConfig). On the rig these were set directly on the node.

## Chain of blockers found (in order)
1. Wrong initdata annotation key → initdata never delivered (CDH empty).            [FIXED]
2. `create_container_timeout = 60` too short.                                       [FIXED → 600]
3. `mirror.rig.local` not resolvable by cluster DNS.                                [FIXED → CoreDNS forward]
4. Guest registry config missing the **pause/release** image remap (only had ubi9). [FIXED → full remap]
5. kubelet `runtimeRequestTimeout` caps guest pull.                                 [FIXED → 20m]
6. After all of the above + confirmed reachability, kata-cc sandbox creation STILL
   does not complete the in-guest pull.                                            [OPEN]

## Remaining (the genuine open item)
With initdata delivered, all timeouts raised, and the guest able to reach KBS **and** the mirror
(by name and IP, HTTP 200), the kata-cc sandbox still fails to finish creating. The host journal
shows only the shim's `create container timeout`; the in-guest image-rs/CDH/attestation logs do
not forward to the host journal even with kata `enable_debug=true`. `kata-runtime exec` works (via
a `script` pty) but the CVM is too short-lived between retries to reliably hold a shell. Definitive
next step: an **interactive** `kata-runtime exec` session held open during one attempt (or kata
`debug_console`), or raise with the OSC/CoCo team — this is a strong candidate for an OSC 1.12
disconnected-guest-pull product gap (see docs/defects #16). Everything up to the confidential
workload *executing* is proven; this is the last mile.
