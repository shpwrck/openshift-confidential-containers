# Customer in-guest image pull — Artifactory + in-cluster KBS (air-gapped)

Fill-in-the-blanks bundle for wiring **in-guest (CDH) image pull from Artifactory** on the customer
topology: **fully air-gapped**, **bare-metal SEV-SNP**, **in-cluster KBS** (ClusterIP, plain HTTP).
It is the Artifactory translation of the rig's proven mirror recipe
(`docs/notes/airgap-coco-guest-pull.md`). It does **not** replace the Phase-5 attestation setup
(VCEK OfflineStore, RVPS, out-of-band secrets) — it templates the registry-auth pieces and the
rung-a smoke test that sit on top of it.

## Why this fixes the ttrpc error
A `ttrpc` error in pod events on this stack means the kata runtime's call into the guest failed. The
usual root cause is that the guest components have nothing to attest to / no `aa.toml` — so CDH can't
reach the Attestation Agent over the ttrpc socket. Standing up KBS and delivering `aa.toml` via
initdata **is** the fix. Target one green **rung-a** and the ttrpc path is proven whole.

## Files
| File | What it is |
|---|---|
| `initdata.artifactory.toml` | In-cluster (HTTP, no cert pinning) initdata: `aa.toml` + `cdh.toml` with Artifactory resource URIs + Artifactory CA. |
| `registries.conf.artifactory.example` | The `registry-configuration` KBS resource (the one piece the rig script does **not** parameterize). |
| `seed-artifactory-kbs-resources.sh` | Mints the three image-pull KBS resources (`credential`, `security-policy`, `registry-configuration`) for Artifactory. |
| `rung-a-artifactory-pod.yaml` | Smoke-test pod; a green run proves attestation + in-guest Artifactory pull. |

## Placeholders to collect (the whole job is filling these)
| Placeholder | Where | What it is |
|---|---|---|
| `__KBS_SVC__` | initdata | In-cluster KBS service, e.g. `kbs-service.trustee-operator-system.svc:8080` (verify: `oc get svc -n trustee-operator-system`). |
| `__ARTIFACTORY__` | seed script, registries.conf | Artifactory `host:port` **exactly as it appears in image refs**. |
| `__ARTIFACTORY_CA_PEM__` | initdata | Artifactory's serving CA (PEM). One cert per array element; no `insecure=true`. |
| creds | seed script | Either `DOCKERCONFIG_JSON=<path>` (reuse an existing docker config / extracted pull secret) **or** `ARTIFACTORY_USER` + `ARTIFACTORY_PASSWORD_FILE`. Reused content is filtered to the `__ARTIFACTORY__` entry and re-keyed to `test`. |
| `__UPSTREAM_APP_PREFIX__` → `location` | registries.conf | Your app's upstream ref → its Artifactory repo path. |
| pause/release remaps | registries.conf | The sandbox/pause + OpenShift release refs → their Artifactory paths (**required**, not just the app). |
| `HWIDS` | Phase 5 (VCEK) | Lowercase 128-hex HWID per SNP chip (`scripts/collect-vcek.sh`). |

## Two ways to build it
**(A) Fast — reuse the rig scripts with env overrides.** Most secrets are already parameterized.
If all you have is a `.dockerconfigjson` (the customer model), hand it over whole — the script
reads the `__ARTIFACTORY__` entry out of it verbatim (no user/password extraction needed):
```bash
ARTIFACTORY_REGISTRY=__ARTIFACTORY__ MIRROR_PULL_SECRET=<path-to-dockerconfigjson> \
MIRROR_CA=<artifactory-ca.pem> \
HWIDS=<hwid1[,hwid2]> scripts/seed-trustee-secrets.sh
```
(With separate credentials instead, drop `MIRROR_PULL_SECRET` and set `MIRROR_USERNAME=<user>
MIRROR_PASSWORD_FILE=<token-file>`.)
This keys `credential` + `security-policy` + VCEK + out-of-band secrets to Artifactory correctly.
Then **replace only** `registry-configuration` with your hand-authored remap (the script hard-codes
rig repo paths):
```bash
oc -n trustee-operator-system create secret generic registry-configuration \
  --from-file=test=registries.conf.artifactory.filled --dry-run=client -o yaml | oc apply -f -
```
`scripts/apply-rung-kbs.sh` is likewise env-driven — set `KBS_URL`, `MIRROR_CA`, `MIRROR_DOMAIN`,
`MIRROR_DNS_UPSTREAM`, `RUNG_KBS_IMAGE`, `NS` for Artifactory and it renders + launches the
rung-a smoke pod for you.

**(B) Standalone — hand raw artifacts to the customer.** Fill the four files here, run
`seed-artifactory-kbs-resources.sh`, encode the initdata, apply the pod.

## Order of operations (your Phase 5 → 6)
1. **Out-of-band secrets first** (`kbs-auth-public-key`, `attestation-cert`, `attestation-status`,
   `sample`) — KBS crash-loops without them and it looks like an attestation failure.
2. **VCEK OfflineStore** — `scripts/collect-vcek.sh` per chip (air-gap: get URL on the node, download
   `.der` on a connected host, carry in). Mount lowercase-HWID into `KbsConfig.kbsLocalCertCacheSpec`;
   set `vcek_sources = [{type="OfflineStore"}]` and **omit KDS**.
3. **Artifactory KBS resources** — path (A) or (B) above.
4. **Deploy Trustee** — `scripts/apply-trustee.sh` (`AllInOneDeployment`; attestation-policy key
   `default_cpu.rego` emitting AR4SI `trust_claims`, not bare `allow := true`). Wait for
   `trustee-deployment` Ready.
5. **Finalize + measure initdata** — fill `initdata.artifactory.toml`, encode, then **regenerate RVPS
   on the bastion** (`gen-rvps-veritas.sh` with a merged authfile — quay tags-list isn't redirected by
   registries.conf). Any later initdata edit re-measures HOST_DATA → regenerate RVPS again.
6. **Rung-a** — apply `rung-a-artifactory-pod.yaml`. Green = ttrpc path proven; move to signed images.

## Load-bearing gotcha checklist
- [ ] initdata annotation key is exactly `io.katacontainers.config.hypervisor.cc_init_data`.
- [ ] `registry_configuration_uri = kbs:///…` used (inline `[image.registry_config]` is silently ignored).
- [ ] Artifactory CA in `extra_root_certificates`, one cert per array element; **no** `insecure=true`.
- [ ] registries.conf includes the **pause/sandbox + release** remaps, not just the app image.
- [ ] `credential` auth key = the Artifactory `host:port` (the mirror location), not the upstream registry.
- [ ] Reusing a dockerconfig: serve it *through KBS* as `credential` (the guest can't read the host pull
      secret), store it under the dotless key `test` (not `.dockerconfigjson`), and confirm the entry has
      an inline base64 `auth` (credHelpers/identitytoken don't work in-guest).
- [ ] `security-policy` has a `transports` block (bare `default` fails "Invalid image policy file").
- [ ] KBS resource names have **no dots** (`regcred`, not `.dockerconfigjson`).
- [ ] CoreDNS resolves the Artifactory hostname **in-guest** (patch `dns.operator/default` if it only
      lives in an internal resolver).
- [ ] Timeouts raised: kata `create_container_timeout=600`, kubelet `runtimeRequestTimeout=20m`.
- [ ] Pod memory limit ≥ `default_memory` + ~256Mi (else QEMU OOM → `DeadlineExceeded`).
- [ ] NFD labeled the node `amd.feature.node.kubernetes.io/snp=true` and `kata-cc` handler = `kata-snp`.

## Verify
```bash
oc get runtimeclass kata-cc -o jsonpath='{.handler}{"\n"}'      # want kata-snp / kata-qemu-snp
oc -n trustee-operator-system rollout status deploy/trustee-deployment
oc -n trustee-operator-system logs deploy/trustee-deployment | grep -iE 'attest|resource|40[13]'
oc get pod rung-a-secret -o wide                                # want Running
oc logs pod/rung-a-secret -c attestation-gate                   # want "attestation: ok"
```
Deeper in-guest debugging (catch the CVM, `kata-runtime exec`): `docs/runbooks/rung-kbs-guest-debug.md`.
Full symptom→cause→fix by phase: `docs/runbooks/failure-modes.md`.
