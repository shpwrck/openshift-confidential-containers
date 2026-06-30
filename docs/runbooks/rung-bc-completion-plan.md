# Rung b/c completion plan

Status: repo scaffolding exists, but this is not proof that both rungs are complete.
Rung-a and the air-gapped in-guest image pull were proven on the rig on 2026-06-29.
Rung-c has live hardware accept/deny evidence. Rung-b has image artifacts and the KID/KEK
mismatch has been diagnosed: the current encrypted layer unwraps with
`/home/rocky/rung-b/kek.bin`, and a local-storage alias diagnostic reached `Running` after
Trustee was reseeded with that key. Rung-b still needs a direct digest-pinned proof path
that reaches guest pull without CRI-O host-side encrypted-layer pre-pull blocking it first;
the CRI-O allowed-annotation and runtime `default_annotations` override paths have also been
ruled out as production proof routes, as has disabling CRI-O's configured host decryption key path.
The remaining direct-pull blocker is tracked upstream in
<https://github.com/cri-o/cri-o/issues/10084>.
The tag-shaped diagnostic path can run the real encrypted image in guest. The rig baseline is
restored to permissive Trustee policy/RVPS after probes, but the restrictive proof window is now
understood: Veritas RVPS generation for the current rung-b initdata is proven on the rig, including
the disconnected release-image workaround, and a later tag-shaped diagnostic proved key release
can be made selective. Trustee's resource policy must inspect
`input.submods[*]["ear.trustworthiness-vector"].configuration`, and the EAR policy must compare
the live SNP HOST_DATA claim exposed as SHA-256 `input.init_data`, not the SHA-384 Veritas
`init_data` value for the same TOML. The repo now renders that policy pair, but the policy result
is still diagnostic until it is replayed with a direct digest-pinned encrypted-image path.

For the latest branch/PR status and remaining proof checklist, see
`docs/runbooks/rung-bc-status.md`. For the filed upstream summary of the remaining direct
encrypted-image blocker, see `docs/runbooks/rung-b-upstream-escalation.md` and
<https://github.com/cri-o/cri-o/issues/10084>.

Upstream mechanics to keep close while implementing:

- Encrypted images: <https://confidentialcontainers.org/docs/features/encrypted-images/>
- Signed images: <https://confidentialcontainers.org/docs/features/signed-images/>
- Initdata and image pull config: <https://confidentialcontainers.org/docs/features/initdata/>

## Current baseline

The rig already proved the hard shared path for b/c:

- `kata-cc` workload launches inside an SNP confidential VM.
- Initdata is delivered with `io.katacontainers.config.hypervisor.cc_init_data`.
- CDH fetches `credential`, `security-policy`, and `registry-configuration` from KBS.
- The guest pulls workload images from the bastion mirror over HTTPS using the mirror CA in
  initdata.
- Trustee uses OfflineStore VCEKs, not public KDS, and the guest-pull path works in the
  air-gapped cluster.

Do not treat that as rung b/c completion. It proves the transport and attestation plumbing.
Rung b must prove key-gated encrypted layers. Rung c must prove signature policy enforcement.

## Non-negotiable invariants

1. Keep every test fail-closed. A pod that reaches `Running` during a negative test is a
   sign-off blocker.
2. Use digest-pinned images for all proof runs. Tags are only labels for humans.
3. Do not edit measured initdata casually. Any KBS URL, CA, registry config, image policy URI,
   or policy choice changes HOST_DATA. For this SNP/OSC path, the enforced HOST_DATA claim is the
   SHA-256 of the TOML because the initdata declares `algorithm = "sha256"`; regenerate both the
   Veritas launch measurements and the SHA-256 policy input when initdata changes.
4. Keep real secrets out of git. KBS resource shape belongs in docs/scripts; keys and passwords
   are created out-of-band on the target cluster.
5. Do not make the pause/release image the accidental failing image. Any restrictive
   `image_security_policy` must explicitly allow or verify every image pulled inside the CVM,
   including OpenShift release/pause images.
6. Verify with three signals: pod phase/events, Trustee KBS logs, and bastion mirror access
   logs. Pod logs alone are too late for image-pull failures.

## Phase 0 - lock choices before touching the rig

Decide and record these values in the run output:

| Decision | Recommendation | Why |
|---|---|---|
| Rung b key URI | `kbs:///default/image-key/rung-b` | Kubernetes Secret names cannot use `_`; `image-key` matches the repo's hyphenated KBS resource pattern. |
| Rung c signing mode | cosign key pair, offline public-key verification | Smallest rig blast radius and matches current CoCo signed-image docs. Fall back to simple signing only if OSC 1.12 image-rs rejects the cosign policy. |
| Rung c policy key | `kbs:///default/security-policy/rung-c` | Avoids replacing the permissive `security-policy/test` used by rung-a troubleshooting. |
| Rung c public key URI | `kbs:///default/sig-public-key/rung-c` | Mirrors the upstream signed-image resource naming. |
| Test workload image | a tiny UBI-based image with an obvious file or log line | Lets us distinguish app start from sandbox/pause pull. |
| Registry path | `mirror.rig.local:8443/coco/rung-b` and `mirror.rig.local:8443/coco/rung-c` | Keeps proof artifacts separate from mirrored OpenShift content. |

Before implementation, confirm the actual image reference string evaluated by image-rs policy.
The repo's proven permissive policy keyed on the mirror host, but the exact signed-policy
entry may need to match the remapped mirror reference that appears in the image-rs/KBS error.

## Phase 1 - prepare artifact tooling

The repo now carries the dry-run friendly tooling:

- `scripts/build-rung-images.sh`
  - Inputs: `MIRROR_REGISTRY`, `SOURCE_IMAGE`, `SOURCE_IMAGE_REF`, `ARTIFACT_DIR`,
    `RUNG_B_IMAGE`, `RUNG_C_IMAGE`, `RUNG_C_UNSIGNED_IMAGE`, `RUNG_B_KEY_PATH`,
    `RUNG_B_KEY_ID`, `RUNG_B_KEY_FILE`, `COCO_KEYPROVIDER_IMAGE`, `CONTAINER_RUNTIME`,
    `CONTAINER_VOLUME_SUFFIX`, `COSIGN_KEY`, `COSIGN_PUB`, `COSIGN_SIGN_ARGS`,
    `COSIGN_VERIFY_ARGS`, and `COSIGN_PASSWORD`.
  - Imports `SOURCE_IMAGE`, defaulting to the pinned UBI image used by rung-a.
  - Creates a 32-byte rung-b image key.
  - Encrypts the rung-b image with the CoCo keyprovider and KID
    `kbs:///default/image-key/rung-b`.
  - Pushes an unsigned rung-c negative-control image, then pushes rung-c and signs the
    digest ref that will be used by the workload.
  - Writes `rung-bc-artifacts/rung-bc-images.json` with digest refs, key paths, and non-secret
    SHA-256 fingerprints for the rung-b key file and rung-c public key file.
  - Writes `rung-bc-artifacts/rung-bc.env`, a sourceable non-secret env file with the digest
    refs, rung-b KID, and artifact paths needed by the apply and negative-test targets;
    malformed manifests or tag-only image refs fail closed instead of producing exports.
- `scripts/seed-trustee-secrets.sh`
  - `RUNG_B_KEY_FILE` creates the Secret/key derived from `RUNG_B_KEY_ID`, defaulting to
    Secret `image-key` with key `rung-b`.
  - `RUNG_C_COSIGN_PUB` creates Secret `sig-public-key` with key `rung-c`.
  - `RUNG_C_POLICY_FILE` creates key `rung-c` on Secret `security-policy`; if omitted and
    `RUNG_C_COSIGN_PUB` is set, the script generates a default signed-image policy.
  - The generated rung-c policy derives its signed-image repository prefix from `RUNG_C_IMAGE`;
    set `RUNG_C_POLICY_IMAGE_PREFIX` only when image-rs reports a different policy key.
  - Existing `security-policy/test` remains the permissive rung-a troubleshooting policy.
- Make targets:
  - `make build-rung-images`
  - `make seed-rung-bc-secrets`
  - `make apply-trustee-rung-bc`
  - `make apply-rung-b`
  - `make apply-rung-c`
  - `make collect-rung-bc-evidence`
  - `make validate-rung-bc-evidence`
  - `make prove-rung-bc`

Makefile namespace convention: `NS` is the Trustee namespace, defaulting to
`trustee-operator-system`; `WORKLOAD_NS` is the namespace for rung pods and negative-test pods,
defaulting to `default`.

On the bastion or connected host that can push to the mirror:

```bash
# one-time, in a checkout of confidential-containers/guest-components:
podman build -t coco-keyprovider -f ./attestation-agent/docker/Dockerfile.keyprovider .

# then in this repo:
COSIGN_PASSWORD='<secret>' make build-rung-images
. rung-bc-artifacts/rung-bc.env
```

The `apply-rung-b`, `apply-rung-c`, and b/c negative-test render paths intentionally reject
tag-only image references. The tag defaults are build destinations; proof runs must use the
`@sha256:...` refs from `rung-bc.env` or `rung-bc-images.json`.

If the keyprovider image has a different local name, pass
`COCO_KEYPROVIDER_IMAGE=<image-name>` to `make build-rung-images`.

Operator-facing artifact knobs:

| Variable | Default | Use when |
|---|---|---|
| `SOURCE_IMAGE` | Rung-a UBI image digest | The proof image should start from a different app image. |
| `SOURCE_IMAGE_REF` | `docker://$(SOURCE_IMAGE)` | The source is local or already staged, e.g. `dir:/path/to/oci`. |
| `SKOPEO_COPY_ARGS` | `--remove-signatures` | The mirror rejects source signature attachment writes, or a registry needs extra copy flags. Rung-c is signed after copy, so source signatures are intentionally stripped by default. |
| `ARTIFACT_DIR` | `./rung-bc-artifacts` | You want generated keys/manifests outside the checkout. |
| `WORKLOAD_NS` | `default` | Rung proof pods should run outside the default namespace. |
| `KBS_URL` | `http://kbs-service.trustee-operator-system.svc:8080` | The measured initdata must point at a different Trustee/KBS endpoint. |
| `RUNG_B_IMAGE` | `$(MIRROR_REGISTRY)/coco/rung-b:encrypted` | The encrypted image should land at a different mirror path/tag. Use the generated digest ref for apply/negative-test. |
| `RUNG_C_IMAGE` | `$(MIRROR_REGISTRY)/coco/rung-c:signed` | The signed image should land at a different mirror path/tag. Use the generated digest ref for apply. |
| `RUNG_C_UNSIGNED_IMAGE` | `$(MIRROR_REGISTRY)/coco/rung-c-unsigned:unsigned` | You want a differently named unsigned negative-control image. Keep this in a repository separate from `RUNG_C_IMAGE` so signatures attached to the signed repo do not satisfy the negative control. Use the generated digest ref for negative-test. |
| `RUNG_B_APP_LOG_MARKER` | `rung-b: encrypted image decrypted and running` | The rung-b proof workload emits a different success line. Validation uses the marker when logs expose it, and falls back to pod/container status when logs are unavailable. |
| `RUNG_C_APP_LOG_MARKER` | `rung-c: signed image accepted and running` | The rung-c proof workload emits a different success line. Validation uses the marker when logs expose it, and falls back to pod/container status when logs are unavailable. |
| `RUNG_C_POLICY_IMAGE_PREFIX` | repository derived from `RUNG_C_IMAGE` | The runtime reports a different `transports.docker` key than the generated prefix. |
| `RUNG_B_KEY_PATH` | `/default/image-key/rung-b` | The KBS resource path must change for the target cluster. |
| `RUNG_B_KEY_ID` | `kbs://$(RUNG_B_KEY_PATH)` | The encrypted layer KID must be set explicitly. If the keyprovider generated `kbs:///default/image-kek/<uuid>`, pass that value so Trustee seeding and evidence validation use the matching Secret/key. |
| `RUNG_B_POLICY_URI` | `kbs:///default/security-policy/test` | The rung-b measured initdata should use a different image policy URI. |
| `RUNG_C_POLICY_URI` | `kbs:///default/security-policy/rung-c` | The rung-c measured initdata should fetch the signed-image policy from a different KBS URI. |
| `RUNG_B_KEY_FILE` | `$(ARTIFACT_DIR)/rung-b-image.key` | Reusing a pre-generated image key or writing it elsewhere. The builder, Trustee renderer, and Trustee seeder reject anything other than exactly 32 bytes. |
| `COCO_KEYPROVIDER_IMAGE` | `coco-keyprovider` | The local keyprovider image has a custom name. |
| `CONTAINER_RUNTIME` | auto-detect `podman`, then `docker` | Both runtimes are installed or the keyprovider runs under a wrapper. |
| `CONTAINER_VOLUME_SUFFIX` | `:Z` for podman, empty otherwise | SELinux or Docker volume semantics need a different suffix. |
| `COSIGN_KEY` / `COSIGN_PUB` | `$(ARTIFACT_DIR)/cosign.{key,pub}` | Reusing or separating signing key material. |
| `COSIGN_SIGN_ARGS` | auto: `--yes --tlog-upload=false`, plus cosign v3 compatibility flags when supported | The mirror/PKI requires exact signing flags. |
| `COSIGN_VERIFY_ARGS` | auto: `--insecure-ignore-tlog=true` | Local verification needs exact offline flags. |

The Makefile passes these values through directly to the builder; `COSIGN_PASSWORD` stays as
an ambient secret environment variable and is intentionally not spelled out in the recipe. With
cosign v3, the builder appends `--new-bundle-format=false` and
`--use-signing-config=false` when those flags are supported, matching the signature format that
CoCo image-rs expects for the signed-image proof.

Dry-run acceptance:

- `skopeo inspect` on rung-b shows
  `org.opencontainers.image.enc.keys.provider.attestation-agent` and the decoded `kid` equals
  `kbs:///default/image-key/rung-b`.
- `wc -c "$RUNG_B_KEY_FILE"` reports `32`; the scripts reject any other key length before
  encryption or Trustee seeding.
- `cosign verify --key <cosign.pub> <rung-c-image>@<digest>` succeeds on the connected/bastion
  side.
- No private key, image key, registry credential, or generated initdata lands in git.

## Phase 2 - add Trustee resources deliberately

Do not add `image-key` and `sig-public-key` to applied `KbsConfig` until their Kubernetes
Secrets exist. Otherwise Trustee may fail in a way that looks like an attestation problem.

Sequence:

1. Create or update Secrets and render Trustee with the extra KBS resource names:

   ```bash
   make apply-trustee-rung-bc \
     RUNG_B_KEY_FILE=rung-bc-artifacts/rung-b-image.key \
     RUNG_C_COSIGN_PUB=rung-bc-artifacts/cosign.pub
   ```

2. Verify the intended resources exist:

   - The Secret/key derived from `RUNG_B_KEY_ID`, bytes exactly equal to the 32-byte
     encryption key.
   - `sig-public-key`, key `rung-c`, bytes equal to `cosign.pub`.
   - `security-policy`, key `rung-c`, JSON policy for signed image verification.
   - `KbsConfig.spec.kbsSecretResources` includes the rung-b key Secret resource and
     `sig-public-key`.
3. Reconcile Trustee and verify KBS logs show no missing resource errors.
4. From a known-good confidential pod, use CDH to request non-sensitive resources first
   (`attestation-status/status`) to prove attestation still works before trying image pulls.

The rung-c policy should start strict for the proof image, but permissive for infrastructure
images the CVM must pull. Skeleton:

```json
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "mirror.rig.local:8443/coco/rung-c": [
        {
          "type": "sigstoreSigned",
          "keyPath": "kbs:///default/sig-public-key/rung-c"
        }
      ],
      "mirror.rig.local:8443/openshift/release": [
        {"type": "insecureAcceptAnything"}
      ],
      "mirror.rig.local:8443/openshift/release-images": [
        {"type": "insecureAcceptAnything"}
      ],
      "mirror.rig.local:8443/ubi9": [
        {"type": "insecureAcceptAnything"}
      ]
    }
  }
}
```

The generated policy uses `RUNG_C_IMAGE` with any tag or digest stripped as its signed-image
key. Adjust `RUNG_C_POLICY_IMAGE_PREFIX` only if image-rs reports a different
`transports.docker` key in events/logs. If the sandbox image is rejected before the app image is
evaluated, the policy is too narrow.

## Phase 3 - implement rung b

Artifacts now present:

- `gitops/base/workloads/rung-b-encrypted-pod.yaml`
- `scripts/apply-rung-b.sh`
- Make target `apply-rung-b`
- `scripts/negative-test.sh` has a real `rung-b` branch that renders a tampered-initdata pod.

Workload shape:

- `runtimeClassName: kata-cc`
- Same memory-floor annotations and limits as rung-a.
- Same rendered initdata pattern as rung-a unless the KBS policy URI changes.
- App image: digest-pinned encrypted image from `mirror.rig.local:8443/coco/rung-b@sha256:...`
- `imagePullPolicy: Always` while proving, to avoid stale node snapshotter state. On the
  2026-06-30 rig this is also the remaining blocker: direct digest and tag refs are still
  intercepted by host-side encrypted-layer handling before Kata/CDH can pull in guest.

Happy path:

1. Confirm rung-a still runs.
2. Confirm the KBS resource derived from `RUNG_B_KEY_ID` is served by Trustee. Do not trust
   the KID string alone; if reusing or importing an image, decode the encrypted layer
   annotation and confirm the Trustee Secret bytes unwrap that layer key.
3. Apply rung-b pod:

   ```bash
   make apply-rung-b RUNG_B_IMAGE="$RUNG_B_IMAGE"
   ```

4. Wait for `Running`.
5. Confirm KBS logs show:
   - successful SNP attestation
   - `GET /kbs/v0/resource/<path-derived-from-RUNG_B_KEY_ID> ... 200`
6. Confirm mirror logs show encrypted image manifest/layer pulls by `oci-client`.
7. Confirm the app log, pod/container status, or filesystem evidence proves the decrypted image started.

Negative path:

Use a measurement mismatch, not a missing image key, as the primary proof:

1. Start from the exact happy-path rung-b manifest and initdata.
2. Tamper measured initdata in a harmless way, such as changing the rung-local
   `security-policy` key or adding a comment field in TOML, and do not regenerate RVPS.
3. Apply the tampered pod as `negtest-rung-b`.
4. Expected result: pod never reaches `Running`/`Succeeded`; KBS logs show attestation or
   measurement denial; `image-key/rung-b` is not released.

Secondary diagnostic negative, only if needed: temporarily remove or rename the
`image-key/rung-b` resource. That proves image decryption depends on KBS material, but it is
not the sign-off proof because it does not prove measurement enforcement.

Before spending more time on the rung-b negative, verify Trustee is no longer in the permissive
bring-up baseline. The live 2026-06-30 tag diagnostic showed
`rvps-reference-values: []`, `resource-policy` as `default allow := true`, and an attestation
policy that affirms every EAR claim; with that state, a tampered-initdata pod still reached
`Running` and fetched `image-kek`. That is a sign-off blocker, not a successful negative.

RVPS generation itself is no longer the blocker. On 2026-06-30,
`scripts/gen-rvps-veritas.sh` generated a `rvps-reference-values` ConfigMap for the current
rung-b initdata on `sno-coco-node` with `OCP_VERSION=4.20.18` and a temporary
`VERITAS_OC_WRAPPER` that rewrote Veritas's hard-coded public release refs to the rig mirror.
The output
`/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rvps-probe-20260630T045611Z/veritas-rung-b-rvps-script.yaml`
has `sha256:f80ced520abeabbe823bc9f9e7afc05a7ed657951a7d82befc6990dc51aa307f` and contains
96 SNP launch measurements plus one `init_data` value. That `init_data` value is the SHA-384 of
the TOML, while Trustee's SNP verifier exposes the live HOST_DATA claim as the 32-byte SHA-256
`input.init_data` value when the initdata TOML says `algorithm = "sha256"`. Do not apply the
Veritas output as proof by itself: pair the launch measurements with a restrictive resource policy
and render the HOST_DATA/SHA-256 value into the EAR appraisal policy, then rerun both the happy and
tampered-initdata pods.

Render the policy pair with `make render-rung-b-measurement-policy INITDATA=<rendered-initdata.toml>
RUNG_B_KEY_ID=<kbs-uri>`, then apply the output only for the restrictive proof window.

The minimal policy shape proven in the tag-shaped diagnostic path was:

```rego
# attestation-policy default_cpu.rego excerpt
default configuration := 36

configuration := 2 if {
  input.init_data == "<sha256-of-rendered-initdata-toml>"
}
```

```rego
# resource-policy policy.rego excerpt
allow if {
  image_key_request
  some sm
  input["submods"][sm]["ear.trustworthiness-vector"]["configuration"] == 2
}
```

Do not use `input["submods"][sm]["ear.status.configuration"]`; `ear.status` is a status string,
not the numeric trustworthiness vector. On 2026-06-30, the current happy initdata SHA-256 was
`a6ae0bdf358463ff272bba868c06c33a80c0b5a6678fac3936dbd66ab27efae0`. The tag diagnostic with
that literal reached `Running` and got `image-kek` HTTP 200; the same policy denied a tampered
initdata pod with `image-kek` HTTP 401/`PolicyDeny`. This proves the policy gate, but it remains
diagnostic because it used the local tag alias rather than the direct digest-pinned encrypted
image.

The 2026-06-30 rig used KID
`kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`. Trustee initially served
`/home/rocky/rung-b/image-kek.bin` at that KID, but offline unwrap showed the encrypted layer
was wrapped with `/home/rocky/rung-b/kek.bin`. After reseeding Trustee with `kek.bin`, a
local node-storage alias diagnostic reached `Running`; that diagnostic is not a production
proof because the container status image ID reflects the local alias/carrier path, not the
direct digest-pinned encrypted image.

Do not spend more rig time trying to pre-stage the actual encrypted image into CRI-O's local
storage without a new mechanism. On this CRI-O 1.33/Kata 3.25 stack, `runtime_pull_image` only
adds Kata's `image_guest_pull` virtual volume during `CreateContainer`, after local image status
succeeds. CRI-O's `PullImage` path still invokes containers/image with a non-nil ocicrypt decrypt
config, so encrypted digest refs fail before `CreateContainer`; attempting to bypass that by
copying the encrypted manifest into `containers-storage` fails DiffID validation, and podman cannot
create a digest-shaped carrier tag. A safer storage-aware carrier copy does not help either:
`crictl inspecti` sees the local carrier only under its rung-c/rung-c-unsigned canonical digests,
`podman tag` rejects the rung-b `repo@sha256` target, and `skopeo copy` refuses to copy the carrier
to the encrypted digest because the source manifest digest would not match the destination
reference.

Do not spend more rig time trying to redirect the app image through CRI-O annotations without a
new mechanism. CRI-O rejects `io.kubernetes.cri.image-name` as a runtime allowed pod annotation,
and a temporary runtime `default_annotations` entry for
`io.kubernetes.cri.container-type=container` plus `io.kubernetes.cri.image-name=<encrypted
digest>` still produced a carrier-sourced Kata `image_guest_pull`, no `image-kek` KBS fetch,
and a carrier `Running` pod. That is another diagnostic-only path, not rung-b proof.

Do not treat a custom NRI hook as a proven production route yet. Source inspection of CRI-O 1.33
shows NRI `CreateContainer` adjustments can update OCI annotations after CRI-O has written its
internal `io.kubernetes.cri-o.ImageName` value and before the VM runtime create call, but the
adjusted annotations are still filtered through the runtime `allowed_annotations` list. The rig
has `/var/run/nri/nri.sock`, but no reusable `/opt/nri`, `/etc/nri`, or `/usr/libexec/nri` plugin
setup. More importantly, NRI runs after CRI-O's image status/pull work, so it cannot prevent the
host-side pull failure for a pod whose original image is the encrypted digest. At most, a custom
NRI probe could diagnose a local carrier-image path by changing the later Kata `image_guest_pull`
source; it would not count as rung-b completion unless adopted as a supported, digest-pinned
OpenShift/CRI-O route and validated with the same happy plus measured-initdata-negative evidence.

Do not spend more rig time trying to disable host-side decrypt by setting CRI-O
`decryption_keys_path` to an empty string without a new mechanism. A 2026-06-30 probe added that
drop-in, restarted CRI-O, and recreated the direct digest pod; the pod still failed with the same
digest-preserving host decrypt error and made no `image-kek` KBS request. The pull still occurs
before Kata guest-pull handoff.

When the direct-pull behavior needs to be rechecked or attached to an upstream report, run
`make diagnose-rung-b-direct-pull RUNG_B_IMAGE="$RUNG_B_IMAGE"` after sourcing
`rung-bc-artifacts/rung-bc.env`. The diagnostic writes a timestamped evidence directory and exits
zero only for the known host-side encrypted-layer blocker with no Trustee image-key request. It
also captures CRI-O node logs plus configured mirror logs/container logs from the diagnostic start
time, so the evidence bundle includes both node-runtime and registry-side views of CRI-O's
pre-guest pull attempt when those logs are available on the bastion. Check `summary.env` for
`crio_log_since_time` and `mirror_log_since_time`, then check `mirror/summary.tsv` for compact
CRI-O-versus-guest rung-b manifest/blob pull counts. Before attaching a diagnostic bundle upstream,
run
`make validate-rung-b-direct-pull DIAG_DIR=<rung-b-direct-pull-dir>` to verify the known blocker,
absence of Trustee image-key requests, bounded CRI-O and mirror-log capture, and mirror-count
shape. Use `REQUIRE_MIRROR_SUMMARY=0` only for older diagnostic bundles collected before mirror
summaries and current log-window metadata existed.

Rung b is done only when happy path and measurement-mismatch negative both reproduce from
written commands.

## Phase 4 - implement rung c

Artifacts now present:

- `gitops/base/workloads/rung-c-signed-pod.yaml`
- `scripts/apply-rung-c.sh`
- Make target `apply-rung-c`
- `scripts/negative-test.sh` has a real `rung-c` branch that renders an unsigned-image pod.

Workload shape:

- `runtimeClassName: kata-cc`
- Same memory-floor annotations and limits as rung-a.
- Initdata must point `image_security_policy_uri` at
  `kbs:///default/security-policy/rung-c`.
- App image: digest-pinned signed image from `mirror.rig.local:8443/coco/rung-c@sha256:...`
- Keep rung c initially unencrypted unless the customer specifically requires a combined
  signed+encrypted proof. Prove signature enforcement in isolation first; then sign the
  encrypted image as a final combined scenario.

Happy path:

1. Confirm rung-b is green or explicitly record that this is an isolated rung-c run.
2. Apply rung-c pod:

   ```bash
   make apply-rung-c RUNG_C_IMAGE="$RUNG_C_IMAGE"
   ```

3. Wait for `Running`.
4. Confirm KBS logs show:
   - successful SNP attestation
   - `GET /kbs/v0/resource/default/security-policy/rung-c ... 200`
   - `GET /kbs/v0/resource/default/sig-public-key/rung-c ... 200`
5. Confirm mirror logs show pulls for the signed image digest.
6. Verify the app log or pod/container status proves the signed image actually started.

Negative path:

Use an unsigned or tampered image reference with the same initdata and same policy:

1. Use the unsigned negative-control image from
   `RUNG_C_UNSIGNED_IMAGE` in `rung-bc-artifacts/rung-bc.env`, or push an otherwise runnable
   image without signing it.
2. Patch only the app image in the rung-c manifest to the unsigned digest.
3. Apply as `negtest-rung-c`.
4. Expected result: pod never reaches `Running`/`Succeeded`; events or runtime errors include
   policy rejection; KBS still releases the policy/key resources only after attestation, but
   image-rs rejects the unsigned/tampered image.

This negative must fail because of `image_security_policy`, not because the mirror, CA,
registry credential, pause image, or KBS URL is broken.

## Phase 5 - update negative-test automation

`scripts/negative-test.sh` now has real b/c branches:

- `rung-a`
  - Render the same initdata/apply path as `make apply-rung-a`.
  - Apply a measured-initdata tamper as `negtest-rung-a`.
  - Require a rung-a attestation/resource-denial signal before counting the proof green.
- `rung-b`
  - Render happy-path initdata.
  - Apply a tampered measured-initdata copy as `negtest-rung-b`.
  - Require a rung-b attestation/image-key denial signal before counting the proof green.
- `rung-c`
  - Render signed-policy initdata.
  - Apply the unsigned/tampered image pod as `negtest-rung-c`.
  - Require a rung-c signature/policy denial signal before counting the proof green.
- `air-gap`
  - Temporarily remove every `vcek-*` Secret in the Trustee namespace, then render an
    otherwise happy rung-a manifest as
    `negtest-air-gap`.
  - The script backs up and restores those Secrets even if the probe exits early.
  - This must fail because the OfflineStore cache is missing, not because the pod manifest was
    also tampered; the harness requires a VCEK/OfflineStore denial signal.

Before declaring the script done, run:

```bash
make negative-test WHICH=rung-a
make negative-test WHICH=rung-b RUNG_B_IMAGE="$RUNG_B_IMAGE"
make negative-test WHICH=rung-c RUNG_C_UNSIGNED_IMAGE="$RUNG_C_UNSIGNED_IMAGE"
make negative-test WHICH=air-gap
make negative-test WHICH=all
```

`WHICH=all` must exit zero only when rung-a, rung-b, rung-c, and air-gap denial proofs all
run and all fail closed as expected. For reviewer-grade evidence, set `KEEP_DENIED_PODS=1`
when running the rung-b and rung-c negative tests, collect the evidence bundle while those
denied pods still exist, then delete the `negtest-*` pods after validation.

## Phase 6 - evidence capture and promotion checklist

After each happy/negative cycle, collect a non-secret evidence bundle while the pods and recent
logs still exist:

```bash
make collect-rung-bc-evidence
make validate-rung-bc-evidence EVIDENCE_DIR=<bundle path printed above>
```

When rung-b is still blocked and the run intentionally contains only rung-c happy/unsigned
negative pods, validate the signed-image proof subset explicitly:

```bash
make validate-rung-c-evidence EVIDENCE_DIR=<bundle path printed above>
```

This checks the same clean-checkout, bounded Trustee/CRI-O/mirror, digest-ref, KBS fetch,
guest-pull, CRI-O source, initdata, app-start, and denial gates for rung-c only. It is not a
substitute for `make validate-rung-bc-evidence`, which remains the final promotion gate for
both rungs.

Once Trustee has the rung-b/c resources, the one-shot proof runner loads digest refs from
`rung-bc-artifacts/rung-bc.env` when `RUNG_B_IMAGE`, `RUNG_C_IMAGE`, and
`RUNG_C_UNSIGNED_IMAGE` are not already digest-pinned, executes the b/c happy paths, keeps the
b/c denied pods for collection, collects a timestamped evidence bundle, and validates it:

```bash
make prove-rung-bc
```

By default this writes under `rung-bc-artifacts/evidence-<utc-timestamp>/`, which is ignored by
git. The default pod set is `rung-a-secret`, `rung-b-encrypted`, `rung-c-signed`,
`negtest-rung-a`, `negtest-rung-b`, `negtest-rung-c`, and `negtest-air-gap`; override with
`EVIDENCE_PODS="..."` when a rig run uses custom pod names. If the rung-b/c pod names change,
also set `RUNG_B_POD`, `RUNG_C_POD`, `NEG_RUNG_B_POD`, and `NEG_RUNG_C_POD` so
`rung-bc-proof-summary.tsv` can correlate the right pod JSON files. The collector records
those pod role names in `summary.env`, and the validator reuses them when explicit overrides
are not provided, so a custom-named bundle remains self-describing offline. If the proof image
emits custom success text, set `RUNG_B_APP_LOG_MARKER` or `RUNG_C_APP_LOG_MARKER` before
running `make collect-rung-bc-evidence`, `make validate-rung-bc-evidence`, or
`make prove-rung-bc`; the collector records those marker values in `summary.env` so the
bundle can be validated offline later without repeating the overrides. Some CC runs expose an
empty `oc logs` stream even when the container is Ready; in that case the validator accepts the
pod JSON only when the happy pod is Running/Succeeded and the `app` container status proves it
started. `make prove-rung-bc` records the proof start time and passes it as
`TRUSTEE_LOG_SINCE_TIME`, `CRIO_LOG_SINCE_TIME`, and `MIRROR_LOG_SINCE_TIME` to evidence
collection, so Trustee resource-fetch checks, CRI-O image-source checks, and mirror pull checks
are bounded to the proof window. If evidence is collected manually after separate
apply/negative-test commands, set
`TRUSTEE_LOG_SINCE_TIME=<UTC RFC3339 time before the first proof pod>` and
`CRIO_LOG_SINCE_TIME=<same timestamp>` and `MIRROR_LOG_SINCE_TIME=<same timestamp>` yourself.
The CRI-O collector still records that RFC3339 value in `summary.env`, but converts it to the
space-separated timestamp form required by `oc adm node-logs --since` when reading node logs.
The bundle includes pod YAML/describe/logs, per-pod summary TSVs, decoded initdata, bounded
Trustee logs, bounded CRI-O node logs, events, KbsConfig/configmaps, mirror log snippets when
the collector can read them, redacted Trustee
Secret metadata plus data-key names and decoded byte lengths, redacted `vcek-*` Secret
metadata, and copies of `rung-bc-images.json` and `rung-bc.env` when present. `pods/summary.tsv`
indexes every requested pod, including missing pods, so reviewers can quickly check phase,
runtime class, app image, and initdata annotation hash. `trustee/secrets/rung-bc-fingerprints.tsv`
records non-secret decoded lengths and SHA-256 fingerprints for only `image-key/rung-b`,
`sig-public-key/rung-c`, and `security-policy/rung-c`; `rung-bc-proof-summary.tsv` compares
those fingerprints and the happy/negative pod image refs against `rung-bc-images.json`.
`make validate-rung-bc-evidence EVIDENCE_DIR=...` fails if the proof summary has missing or
non-matching required rows, the image manifest has the wrong rung-b KBS key ID, required pod
phases/images are missing or wrong, the bundle lacks Trustee, CRI-O, or mirror log `--since-time` windows,
Trustee logs lack the expected KBS resource fetches, CRI-O logs lack `image_guest_pull` sources
for the expected digest refs, mirror logs lack guest `oci-client` manifest pulls for the expected
rung-b/rung-c image digests,
happy-image mirror logs lack guest `oci-client` blob pulls for the rung-b/rung-c repositories, rung-b
negative decoded initdata does not differ from the happy pod, rung-c negative decoded initdata
does not match the happy pod, decoded initdata is missing or lacks the expected KBS URL, rung policy URI, or
tamper marker, happy pods lack both the expected app-start log markers and pod-status app-start
evidence, negative pods lack denial signals, or the bundle was collected from a dirty checkout. Expected KBS resource fetches are
derived from the recorded rung-b key ID and rung-c policy URI, so custom KBS paths are validated
against their actual Trustee log entries. `summary.env` records the repo revision, branch,
dirty state, expected KBS URL, rung-b key ID, rung policy URIs, expected app-log markers, Trustee,
CRI-O, and mirror log `--since-time` values, and local tool paths used to collect the bundle. It does not dump Secret data, but still review the
bundle before sharing it outside the engagement.

When running from the bastion, the collector automatically tries common nginx, mirror bootstrap,
oc-mirror, and quay container log locations and records CRI-O logs from nodes referenced in
`pods/summary.tsv`. Override as needed; the same CRI-O and mirror log tail settings are also
honored by `make prove-rung-bc`:

```bash
make collect-rung-bc-evidence \
  CRIO_LOG_TAIL=2000 \
  MIRROR_LOG_FILES="/var/log/nginx/access.log /opt/mirror/custom-access.log" \
  MIRROR_CONTAINER_NAMES="quay-app" \
  MIRROR_LOG_TAIL=2000
```

After both rungs are green on the disposable rig:

- Commit the workload manifests, apply scripts, negative-test coverage, and doc updates.
- Record image digests and key IDs in the run notes, not the key material.
- Check `rung-bc-proof-summary.tsv`; every row should be `match` unless the row is for a pod
  that was intentionally deleted before collection, in which case re-run collection while that
  pod still exists if you need reviewer-grade evidence.
- Run `make validate-rung-bc-evidence EVIDENCE_DIR=<bundle>` and treat any failure as a
  sign-off blocker until the underlying rig evidence is fixed.
- Save the `collect-rung-bc-evidence` bundle path with the run notes.
- Re-run `make lint`.
- Re-run the full hardware gate matrix:

```bash
make apply-rung-a
make apply-rung-b
make apply-rung-c
make negative-test WHICH=all
```

- Destroy and recreate the node, then replay from written steps once. A rung is not proven for
  production until it survives replay on a fresh node.
- For production, regenerate hardware-bound values: VCEKs, RVPS, Trustee URL/TLS, initdata,
  image keys, and signing keys or public-key trust material as required by the customer.

## Failure triage

| Symptom | Most likely cause | First checks |
|---|---|---|
| Rung b pod hangs before image-key request | Guest cannot reach KBS or initdata was not delivered | Decode pod annotation; KBS logs; `aa.toml`/`cdh.toml` URL |
| KBS serves image key but decrypt still fails | Wrong key bytes, wrong KID, guest/keyprovider format mismatch, stale snapshotter cache | Decode encrypted layer annotation and run an offline unwrap check without printing key material. On 2026-06-30 the KID was correct, but Trustee served the wrong 32-byte key: `/home/rocky/rung-b/image-kek.bin` failed, while `/home/rocky/rung-b/kek.bin` (`sha256:f85822d4f55b41ed4f915a541a68aa41dece5944db73c269aff292a78fe6684c`) unwrapped the layer. Update Trustee and `rung-bc.env`/`rung-bc-images.json` to the key that actually unwraps the image. |
| Direct encrypted image never reaches KBS; digest ref says the layer cannot be decrypted because the destination specifies a digest, while tag ref says a private key is missing | CRI-O/containers-image is still performing host-side encrypted-layer handling before Kata/CDH can pull in guest | Do not repeat pod-only `experimental_force_guest_pull` probes; on the 2026-06-30 rig, pod annotation and temporary node-level `experimental_force_guest_pull = true` both still failed before any `image-kek` KBS fetch. `imagePullPolicy: Never` only changed the failure to `ErrImageNeverPull`. Escalate to a supported OSC/CRI-O guest-pull path or a different encrypted-image delivery path. |
| Setting CRI-O `[crio.runtime] decryption_keys_path = ""` does not change the direct digest failure | The host pull path still attempts encrypted-layer handling before the Kata guest-pull handoff, independent of this config-only toggle | Do not treat the decryption key path as the remaining knob. Confirm the drop-in is removed, CRI-O restarted, and the node Ready after any probe. |
| Pod annotation `io.kubernetes.cri-o.ImageName` is allowed and set to the encrypted image, but guest pull still uses the carrier image | CRI-O writes its internal `ImageName` after sandbox annotations, so the pod annotation does not override the create-time guest-pull source | Do not use this as a workaround. Confirm with CRI-O journal `Adding mount info to pull image ...`; remove the temporary allowed annotation and restore `50-kata-snp`. |
| Runtime `default_annotations` set `io.kubernetes.cri.image-name` to the encrypted digest, but the pod runs as the carrier and no image-key request appears | CRI-O's create-time app image metadata still resolves from the local carrier image; the containerd-style source annotation does not win for this CRI-O/Kata path | Do not count a carrier `Running` pod as proof. Require both a CRI-O `image_guest_pull` source matching the encrypted ref and a Trustee `image-kek` fetch. Restore `50-kata-snp` after the probe; on the air-gapped rig, use a cached mirror image for `oc debug node` because the default support-tools image can time out. |
| A custom NRI hook appears able to adjust `io.kubernetes.cri-o.ImageName` before Kata create | NRI adjustments are applied after CRI-O creates the local image result and before VM runtime create, but still after the host pull/status decision | Treat this as unproven custom mechanism work, not current proof. A probe would need a temporary runtime `allowed_annotations` entry and a signed/owned NRI plugin; it still cannot stop the direct encrypted digest from failing before `CreateContainer`, so only a supported implementation that preserves the digest-pinned proof invariant can close rung b. |
| Tampered-initdata rung-b negative reaches `Running` and fetches `image-kek` | Trustee is still in permissive bring-up mode, so RVPS/resource/attestation policy is not enforcing the measured initdata mismatch | Check `rvps-reference-values`, `resource-policy`, and `attestation-policy`. Empty reference values plus `default allow := true` plus all-affirming EAR claims mean the negative cannot count. Generate/apply restrictive reference values and rerun before sign-off. |
| Happy rung-b pod is denied by restrictive resource policy even though the EAR policy should affirm `configuration` | The resource policy is reading the wrong EAR field | Use `input["submods"][sm]["ear.trustworthiness-vector"]["configuration"] == 2`; do not use `ear.status.configuration`. A 2026-06-30 probe proved the corrected path releases `image-kek` for the happy tag-shaped diagnostic. |
| Happy rung-b pod is denied by an EAR policy using `query_reference_value("init_data")` | Veritas `init_data` and Trustee SNP HOST_DATA are different hashes for this initdata shape | The Veritas output recorded the SHA-384 of the TOML, while Trustee exposed the live SNP HOST_DATA as the SHA-256 `input.init_data` because the TOML declares `algorithm = "sha256"`. Render the SHA-256 from the exact initdata TOML into the EAR policy, or change the initdata/RVPS generation strategy deliberately and revalidate both happy and tampered pods. |
| `gen-rvps-veritas.sh` fails in a disconnected rig on `quay.io/openshift-release-dev/ocp-release:<version>-x86_64` | Veritas baremetal uses `oc adm release info` against a hard-coded public release tag; mounting `registries.conf` is not enough for that tag path | Set `OCP_VERSION`, use a cached `DEBUG_IMAGE` for `oc debug`, pass mirror-capable auth such as the bastion Docker config, and supply a short-lived `VERITAS_OC_WRAPPER` that rewrites the release and `rhel-coreos-extensions` refs to the mirror. Treat any skipped upstream verify step as a disconnected workaround backed by prior mirror provenance, not as release-integrity proof. |
| Pre-staging the actual encrypted image into `containers-storage` fails before pod creation | containers/storage validates layer DiffIDs against the image config and cannot store the encrypted layer as a normal local rootfs image | On 2026-06-30, `skopeo copy --preserve-digests docker://...@sha256:69b8... containers-storage:...:encrypted-prestage` failed because encrypted blob `sha256:346e9...` did not match config DiffID `sha256:76c30...`. Clean any partial tag and do not treat this as a viable direct bypass. |
| Trying to make a digest-pinned carrier alias fails | Podman/containers-storage do not allow creating tags whose target name is a digest reference | On 2026-06-30, `podman tag <carrier> mirror.rig.local:8443/coco/rung-b@sha256:69b8...` failed with `tag by digest not supported`. A tag-only carrier alias can diagnose guest pull, but it cannot satisfy the digest-pinned production proof invariant. |
| Copying the carrier image to the encrypted digest name with `skopeo` fails | containers/image enforces that a destination `repo@sha256` reference matches the copied manifest digest | On 2026-06-30, `skopeo copy containers-storage:<carrier-digest> containers-storage:mirror.rig.local:8443/coco/rung-b@sha256:69b8...` failed with `Digest of source image's manifest would not match destination reference`. Do not use a carrier image to masquerade as the encrypted digest through supported storage tools. |
| Local node-storage alias reaches KBS but pod stays `CreateContainerError` with `Failed to decrypt the image layer` | Host image check was bypassed, so the remaining issue is guest decryption of the encrypted layer | Treat this only as a diagnostic. Decode layer annotations, compare KID/KEK, and reseed Trustee or rebuild the encrypted image before rerunning direct proof. |
| Local node-storage alias reaches `Running`, but direct encrypted image still never reaches KBS | Guest decryption is fixed, but the production path is still stopped by host-side encrypted-layer pre-pull | Do not count the alias as rung-b completion. Keep the cleanup discipline: remove the temporary pod/tag, restore CRI-O allowed annotations, and continue on a supported OpenShift/CRI-O path that lets the real digest-pinned encrypted image reach guest pull. |
| Rung c rejects signed app image | Policy reference does not match the image-rs evaluated reference, or wrong public key | Pod events; KBS resource paths; `cosign verify`; exact image string in error |
| Rung c rejects pause/release image | Strict policy forgot infrastructure image exceptions | Events/logs show rejected OpenShift release/pause image; add explicit allow/verify entry |
| Negative test reaches Running | RVPS/policy not enforcing measured initdata or wrong manifest was tested | Treat as sign-off blocker; inspect resource policy, RVPS, and rendered initdata bytes |
| No useful pod logs | Failure occurs before container start | Use `oc describe pod`, Trustee logs, and mirror logs instead |
