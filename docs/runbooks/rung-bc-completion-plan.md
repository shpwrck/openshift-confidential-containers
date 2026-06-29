# Rung b/c completion plan

Status: repo scaffolding exists, but this is not proof that the rungs are complete.
Rung-a and the air-gapped in-guest image pull were proven on the rig on 2026-06-29.
Rungs b/c still need image artifacts built on the rig, KBS resources enabled with those
artifacts, and hardware happy/negative test runs.

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
   or policy choice changes HOST_DATA and requires fresh Veritas RVPS before enforcing a
   restrictive measurement policy.
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
  - Writes `rung-bc-artifacts/rung-bc-images.json` with digest refs and key paths.
  - Writes `rung-bc-artifacts/rung-bc.env`, a sourceable non-secret env file with the digest
    refs and artifact paths needed by the apply and negative-test targets.
- `scripts/seed-trustee-secrets.sh`
  - `RUNG_B_KEY_FILE` creates Secret `image-key` with key `rung-b`.
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
`@sha256:...` refs from `rung-bc-images.json`.

If the keyprovider image has a different local name, pass
`COCO_KEYPROVIDER_IMAGE=<image-name>` to `make build-rung-images`.

Operator-facing artifact knobs:

| Variable | Default | Use when |
|---|---|---|
| `SOURCE_IMAGE` | Rung-a UBI image digest | The proof image should start from a different app image. |
| `SOURCE_IMAGE_REF` | `docker://$(SOURCE_IMAGE)` | The source is local or already staged, e.g. `dir:/path/to/oci`. |
| `ARTIFACT_DIR` | `./rung-bc-artifacts` | You want generated keys/manifests outside the checkout. |
| `WORKLOAD_NS` | `default` | Rung proof pods should run outside the default namespace. |
| `RUNG_B_IMAGE` | `$(MIRROR_REGISTRY)/coco/rung-b:encrypted` | The encrypted image should land at a different mirror path/tag. Use the generated digest ref for apply/negative-test. |
| `RUNG_C_IMAGE` | `$(MIRROR_REGISTRY)/coco/rung-c:signed` | The signed image should land at a different mirror path/tag. Use the generated digest ref for apply. |
| `RUNG_C_UNSIGNED_IMAGE` | `$(MIRROR_REGISTRY)/coco/rung-c:unsigned` | You want a differently named unsigned negative-control image. Use the generated digest ref for negative-test. |
| `RUNG_C_POLICY_IMAGE_PREFIX` | repository derived from `RUNG_C_IMAGE` | The runtime reports a different `transports.docker` key than the generated prefix. |
| `RUNG_B_KEY_PATH` | `/default/image-key/rung-b` | The KBS resource path must change for the target cluster. |
| `RUNG_B_KEY_ID` | `kbs://$(RUNG_B_KEY_PATH)` | The encrypted layer KID must be set explicitly. |
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

   - `image-key`, key `rung-b`, bytes exactly equal to the 32-byte encryption key.
   - `sig-public-key`, key `rung-c`, bytes equal to `cosign.pub`.
   - `security-policy`, key `rung-c`, JSON policy for signed image verification.
   - `KbsConfig.spec.kbsSecretResources` includes `image-key` and `sig-public-key`.
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
- `imagePullPolicy: Always` while proving, to avoid stale node snapshotter state.

Happy path:

1. Confirm rung-a still runs.
2. Confirm `image-key/rung-b` is served by Trustee.
3. Apply rung-b pod:

   ```bash
   make apply-rung-b RUNG_B_IMAGE="$RUNG_B_IMAGE"
   ```

4. Wait for `Running`.
5. Confirm KBS logs show:
   - successful SNP attestation
   - `GET /kbs/v0/resource/default/image-key/rung-b ... 200`
6. Confirm mirror logs show encrypted image manifest/layer pulls by `oci-client`.
7. Confirm the app log or filesystem evidence proves the decrypted image started.

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
6. Verify the app log proves the signed image actually started.

Negative path:

Use an unsigned or tampered image reference with the same initdata and same policy:

1. Use the unsigned negative-control image from
   `rung-bc-artifacts/rung-bc-images.json` (`.rung_c.unsigned_digest_ref`), or push an
   otherwise runnable image without signing it.
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
- `rung-b`
  - Render happy-path initdata.
  - Apply a tampered measured-initdata copy as `negtest-rung-b`.
  - Reuse `expect_fail_closed`, but extend the denial grep for `decrypt`, `image-key`,
    `key`, `measurement`, and `attestation`.
- `rung-c`
  - Render signed-policy initdata.
  - Apply the unsigned/tampered image pod as `negtest-rung-c`.
  - Extend denial grep for `Image policy rejected`, `sigstoreSigned`, `signature`,
    `security-policy`, and `rejected`.
- `air-gap`
  - Temporarily remove every `vcek-*` Secret in the Trustee namespace, then render an
    otherwise happy rung-a manifest as
    `negtest-air-gap`.
  - The script backs up and restores those Secrets even if the probe exits early.
  - This must fail because the OfflineStore cache is missing, not because the pod manifest was
    also tampered.

Before declaring the script done, run:

```bash
make negative-test WHICH=rung-a
make negative-test WHICH=rung-b RUNG_B_IMAGE="$RUNG_B_IMAGE"
make negative-test WHICH=rung-c RUNG_C_UNSIGNED_IMAGE="$RUNG_C_UNSIGNED_IMAGE"
make negative-test WHICH=air-gap
make negative-test WHICH=all
```

`WHICH=all` must exit zero only when rung-a, rung-b, rung-c, and air-gap denial proofs all
run and all fail closed as expected.

## Phase 6 - evidence capture and promotion checklist

After each happy/negative cycle, collect a non-secret evidence bundle while the pods and recent
logs still exist:

```bash
make collect-rung-bc-evidence
```

By default this writes under `rung-bc-artifacts/evidence-<utc-timestamp>/`, which is ignored by
git. The default pod set is `rung-a-secret`, `rung-b-encrypted`, `rung-c-signed`,
`negtest-rung-a`, `negtest-rung-b`, `negtest-rung-c`, and `negtest-air-gap`; override with
`EVIDENCE_PODS="..."` when a rig run uses custom pod names. The bundle includes pod
YAML/describe/logs, decoded initdata, recent Trustee logs, events, KbsConfig/configmaps,
mirror log snippets when the collector can read them, redacted Trustee Secret metadata plus
data-key names, redacted `vcek-*` Secret metadata, and a copy of `rung-bc-images.json` if
present. It does not dump Secret data, but still review the bundle before sharing it outside
the engagement.

When running from the bastion, the collector automatically tries common nginx, mirror bootstrap,
oc-mirror, and quay container log locations. Override as needed:

```bash
make collect-rung-bc-evidence \
  MIRROR_LOG_FILES="/var/log/nginx/access.log /opt/mirror/custom-access.log" \
  MIRROR_CONTAINER_NAMES="quay-app"
```

After both rungs are green on the disposable rig:

- Commit the workload manifests, apply scripts, negative-test coverage, and doc updates.
- Record image digests and key IDs in the run notes, not the key material.
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
| KBS serves image key but decrypt still fails | Wrong key bytes, wrong KID, stale snapshotter cache | Decode encrypted layer annotation; compare key size; use `imagePullPolicy: Always`; rebuild node if cache is suspect |
| Rung c rejects signed app image | Policy reference does not match the image-rs evaluated reference, or wrong public key | Pod events; KBS resource paths; `cosign verify`; exact image string in error |
| Rung c rejects pause/release image | Strict policy forgot infrastructure image exceptions | Events/logs show rejected OpenShift release/pause image; add explicit allow/verify entry |
| Negative test reaches Running | RVPS/policy not enforcing measured initdata or wrong manifest was tested | Treat as sign-off blocker; inspect resource policy, RVPS, and rendered initdata bytes |
| No useful pod logs | Failure occurs before container start | Use `oc describe pod`, Trustee logs, and mirror logs instead |
