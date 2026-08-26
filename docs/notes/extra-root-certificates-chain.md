# `extra_root_certificates`: why the chain must be one cert per array element

Investigated 2026-07-29 for a customer whose CoCo workload will not start and whose registry CA is
a real chain (intermediate + root). This note records the **mechanism and its provenance**, because
the repo asserted the conclusion in five places with no traceable evidence behind it.

## The conclusion (unchanged) — but now with a source trace

`cdh.toml`:

```toml
[image]
extra_root_certificates = ["""<one PEM>""", """<one PEM>"""]   # one cert PER element
```

A concatenated multi-cert bundle in a **single** element does not work. The call chain:

| Layer | What it does |
|---|---|
| `image-rs/src/image.rs` | maps each array element to `Certificate { encoding: Pem, data }` — an **opaque blob, no parsing** |
| `oci-client/src/client.rs` | `convert_certificates()` → `reqwest::Certificate::try_from(&Certificate)` |
| same, `TryFrom` impl | `CertificateEncoding::Pem => reqwest::Certificate::from_pem(...)` |

`reqwest::Certificate::from_pem` is the **single-certificate** API. reqwest ships
`from_pem_bundle` for exactly the concatenated-bundle case, and this path does **not** use it.
`convert_certificates` collects into a `Result`, so a rejected element fails the whole client build.

So the guidance is correct, and the reason is one function call, not folklore.

Sources: [guest-components](https://github.com/confidential-containers/guest-components) ·
[rust-oci-client](https://github.com/oras-project/rust-oci-client) ·
[reqwest::tls::Certificate](https://docs.rs/reqwest/latest/reqwest/tls/struct.Certificate.html)

## Two failure modes that look identical from the pod, and are not

Splitting the chain only helps if the client is genuinely the thing missing a certificate. Check
**both** of these before editing initdata:

1. **Client-side (array shape).** Chain concatenated into one element → only one certificate is
   ever considered. If the registry needs an intermediate you did not effectively load, TLS fails.
2. **Server-side (incomplete chain).** If the registry serves its **leaf without its intermediate**
   — a very common Artifactory misconfiguration — then **no client-side array shape helps**. The
   client must then carry root *and* intermediate itself, and if it carries them as a bundle in one
   element (mode 1) it is broken twice over.

Verify the server side first, from anywhere that can reach the registry:

```bash
# What does the registry actually SEND? Count the certs in the presented chain.
openssl s_client -connect <registry-host>:<port> -showcerts </dev/null 2>/dev/null \
  | grep -c 'BEGIN CERTIFICATE'
#   1  -> leaf only: the server is NOT sending its intermediate (fix the SERVER)
#   2+ -> server sends a chain; a client holding just the root should suffice

# Does a client holding only the root verify?
curl -sv --cacert root.pem https://<registry-host>:<port>/v2/ 2>&1 | grep -E 'SSL certificate|verify'
```

## What was and was not proven on the rig (2026-07-29)

**Proven on hardware:**
- A real `root -> intermediate -> leaf` PKI was built and confirmed genuinely chained: `openssl
  verify` fails with `unable to get local issuer certificate` without the intermediate and passes
  with it. This matters — a decoy certificate that plays no part in verification would prove nothing.
- The in-guest client reaches an external endpoint over TLS and pulls: `oci-client/0.15.0`
  handshakes and manifest GETs were observed in the endpoint's access log.
- An nginx endpoint can be switched between serving leaf+intermediate and leaf-only, and a
  root-only client verifiably fails against leaf-only — i.e. a broken chain **is detectable**,
  which is what makes a negative control meaningful.

**NOT proven on hardware:** the A–D matrix distinguishing *bundle-in-one-element* from
*one-per-element* at runtime. Three harness attempts were invalidated by the control failing:

1. pod referenced `:latest` instead of the digest-pinned image — two variables changed at once;
2. quay's bearer auth confounded the pull (removed by fronting a plain unauthenticated registry);
3. the pod referenced the test registry **directly**, which makes **kubelet/CRI-O on the host** do
   the pull (`x509: certificate signed by unknown authority` from kubelet) rather than the guest —
   testing the host trust store, not `extra_root_certificates` at all.

**The trap worth remembering (3):** `extra_root_certificates` only governs the **in-guest** pull. To
exercise it, the pod must reference an **upstream** ref that the host resolves through its own
trusted mirror, with `registries.conf` (served via KBS) remapping it for the guest. Point a pod
directly at a host the kubelet does not trust and you are testing the wrong layer.

The remaining step, if this is ever finished: copy the test image **digest-preserving** (`skopeo
copy --all`; `podman push` recomputes the manifest and changes the digest, which breaks by-digest
pulls) so the host can pull from its mirror while the guest pulls the same digest from the
chain endpoint.
