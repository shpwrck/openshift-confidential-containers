# Rung b/c status

Last updated: 2026-06-30T03:41:00Z

Current PR: #8, `codex/rung-bc-support`
Current head before this update: `e432ba8`
Status: repo scaffolding and local no-hardware validation are green; live rig access is confirmed.
Rung-c now has live happy-path and unsigned-control denial evidence, and offline validation accepts
pod-status app-start evidence when CC logs are empty. Rung-b is not complete. Direct digest/tag
pods are still blocked by CRI-O host-side encrypted-layer pre-pull before guest pull begins, and a
local-alias diagnostic that forced guest pull reached KBS but failed layer decryption inside CDH.

## What is already in place

- Rung-b and rung-c build, seed, apply, negative-test, collect, validate, and one-shot proof targets exist.
- Proof runs require digest-pinned image refs; tag-only proof refs are rejected before apply.
- Rung-b evidence tracks encrypted image key ID, initdata policy URI, Trustee resource fetches, mirror pulls, pod state, app-start evidence, and fail-closed tampered-initdata behavior.
- Rung-c evidence tracks signed image policy URI, public key resource fetch, mirror pulls, pod state, app-start evidence, and fail-closed unsigned-image behavior.
- Evidence bundles record non-secret provenance in `summary.env`, including repo revision, branch, dirty state, KBS URL, policy URIs, pod role names, and app log markers.
- Offline validation derives expected KBS resource log entries from the recorded rung-b key ID and rung-c policy URI, so custom KBS paths are validated against the actual run configuration.
- Trustee seeding now derives the rung-b Secret resource/key from `RUNG_B_KEY_ID`, so a
  keyprovider-generated URI such as `kbs:///default/image-kek/<uuid>` can be seeded and
  fingerprinted instead of forcing every proof into `image-key/rung-b`.
- Initdata encoding now uses deterministic gzip output, and evidence validation compares decoded
  initdata content for happy/negative relationships so gzip metadata cannot create false
  differences.

## Local verification completed

The following no-hardware checks passed on 2026-06-30:

```bash
bash -n scripts/apply-rung-image.sh scripts/collect-rung-bc-evidence.sh scripts/negative-test.sh scripts/prove-rung-bc.sh scripts/validate-rung-bc-evidence.sh scripts/verify-rung-bc-render.sh
shellcheck scripts/apply-rung-image.sh scripts/collect-rung-bc-evidence.sh scripts/negative-test.sh scripts/prove-rung-bc.sh scripts/validate-rung-bc-evidence.sh scripts/verify-rung-bc-render.sh
git diff --check
bash scripts/verify-rung-bc-render.sh
make lint
```

## What is left

Live rig check on 2026-06-30:

- Bastion access works at `rocky@69.67.151.187`; `oc`, `skopeo`, `cosign`, and root `podman` are present.
- The SNO node is Ready and Trustee is running. The initial check found KbsConfig at the rung-a baseline; after this pass, `apply-trustee-rung-bc` added `image-kek` and `sig-public-key`.
- The existing `ghcr.io/confidential-containers/coco-keyprovider:latest` image on the bastion is a runtime keyprovider server with `/usr/local/bin/coco_keyprovider`; it does not contain the `/encrypt.sh` helper assumed by `make build-rung-images`.
- The bastion mirror rejected source signature attachment writes during `skopeo copy`; the builder now defaults `SKOPEO_COPY_ARGS` to `--remove-signatures`, and rung-c signing still happens after the copy.
- The rung-c unsigned negative-control default now uses `coco/rung-c-unsigned`, not another tag in the signed `coco/rung-c` repository, so repository-scoped cosign signature storage cannot accidentally satisfy the unsigned control.
- `rung-bc.env` now exports `RUNG_B_KEY_ID` so apply/prove steps use the exact encrypted-image KID recorded in `rung-bc-images.json` instead of silently reverting to the default key path.
- Prior rig artifacts under `/home/rocky/rung-b` show encrypted OCI images with `kbs:///default/image-kek/<uuid>` KIDs and 32-byte KEK files. The expected `mirror.rig.local:8443/coco/rung-b` and `coco/rung-c` repos were not present in the mirror at this check.
- `apply-trustee-rung-bc` succeeded with `RUNG_B_KEY_ID=kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`, creating `image-kek` and `sig-public-key` resources in KbsConfig.
- Rung-b apply reproduced the CRI-O encrypted-layer blocker: `rung-b-encrypted` stayed `ImagePullBackOff` with kubelet reporting that layer `sha256:346e9...` should be decrypted but the manifest could not be modified because the destination specifies a digest. Trustee logs did not show `resource/default/image-kek/...`, confirming the guest never reached KBS for the image key.
- Rung-c apply succeeded: `rung-c-signed` reached Ready/Running, Trustee logs showed `security-policy/rung-c` and `sig-public-key/rung-c`, and mirror logs showed the signed image digest pull.
- Rung-c negative succeeded: `negative-test.sh rung-c` denied `mirror.rig.local:8443/coco/rung-c-unsigned@sha256:4ba374...` as expected and kept `negtest-rung-c` for evidence.
- Final evidence bundle for this pass: `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/evidence-20260630T023159Z` on the bastion. With the current validator, this bundle passes the rung-c happy pod, pod-status app-start, same decoded initdata, Trustee fetch, unsigned image, and denial checks. It still exits non-zero on seven rung-b items: missing rung-b negative image proof-summary row, happy pod Pending, app container not started, missing rung-b negative pod, missing rung-b decoded negative relationship, missing rung-b negative decoded initdata, and missing Trustee fetch for `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`. `oc exec` into the rung-c pod remains blocked by policy.
- Additional rung-b force-guest-pull probes on the same rig did not move the encrypted pull into
  the guest:
  - The live `kata-snp` config had `experimental_force_guest_pull = false`; `runtime_pull_image =
    true` was already set in CRI-O's `50-kata-snp` runtime config.
  - Adding pod annotation `io.katacontainers.config.runtime.experimental_force_guest_pull=true`
    to a separate `rung-b-force-guest-pull` pod still failed with the digest-ref encrypted-layer
    host-pull error and no `image-kek` Trustee fetch.
  - Temporarily setting `/etc/kata-containers/kata-snp/configuration.toml` to
    `experimental_force_guest_pull = true` and restarting CRI-O did not change the digest-ref
    failure. A tag-ref diagnostic pod changed the message to host-side `missing private key needed
    for decryption`, again with no `image-kek` Trustee fetch.
  - The node config was restored from the backup and the node returned Ready.
- Additional 2026-06-30 rung-b probes narrowed the remaining blocker:
  - Patching the digest-pinned pod to `imagePullPolicy: Never` avoided host pull, but kubelet
    refused the pod with `ErrImageNeverPull`; no KBS image-key fetch occurred.
  - Temporarily allowing pod annotation `io.kubernetes.cri-o.ImageName` in CRI-O and running an
    unencrypted carrier image did not redirect Kata's guest-pull source. CRI-O still emitted
    `image_guest_pull` for the carrier image, the pod ran as the carrier, and no rung-b image-key
    fetch occurred. The CRI-O config was restored and the node returned Ready.
  - A diagnostic local-storage alias did get past the host image check: root `podman tag` pointed
    the already-present unencrypted carrier image at `mirror.rig.local:8443/coco/rung-b:encrypted`,
    and the pod used that tag with `imagePullPolicy: IfNotPresent`. Kubelet reported the image was
    already present; CRI-O emitted `image_guest_pull` for `coco/rung-b:encrypted`; Trustee served
    `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c` with HTTP 200 repeatedly.
    The pod still stayed `CreateContainerError` because CDH failed to decrypt the image layer
    (`Failed to decrypt the image layer, please ensure that the decryption key is placed and
    correct`). The temporary pod and local alias were removed. This proves KBS reachability and
    key release once guest pull is reached, but it does not prove a successful encrypted-image run.

1. Reconcile the rung-b encrypted image, KID, KEK bytes, and guest decryption format:

   - Decode the encrypted layer annotation for
     `mirror.rig.local:8443/coco/rung-b@sha256:69b8fa1c66919ff9d4412fc6ecd0139aa78883c93fdfc78db0aecd526de0890c`.
   - Confirm it references `kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`.
   - Confirm the Trustee Secret data is byte-for-byte the KEK that the keyprovider used.
   - If those match, rebuild rung-b with the same guest-components/keyprovider format expected by
     the rig's CDH/image-rs stack, then rerun the local-alias diagnostic before attempting the full
     proof.

2. Find a supported OpenShift/CRI-O path that gets direct rung-b pods to `CreateContainer` without
   host-side encrypted-layer pre-pull. The diagnostic local alias is useful for root-cause work, but
   it is not a production proof path.

3. Build and push any rebuilt rung-b encrypted image and rung-c signed plus unsigned-control images on the bastion or connected host:

   ```bash
   COSIGN_PASSWORD='<secret>' make build-rung-images
   . rung-bc-artifacts/rung-bc.env
   ```

4. Seed Trustee with the rung-b image key, rung-c public key, and rung-c signed-image policy, then reconcile Trustee:

   ```bash
   make apply-trustee-rung-bc \
     RUNG_B_KEY_FILE=rung-bc-artifacts/rung-b-image.key \
     RUNG_C_COSIGN_PUB=rung-bc-artifacts/cosign.pub
   ```

5. Run the hardware proof on the disposable rig:

   ```bash
   make prove-rung-bc
   ```

6. Keep the generated evidence bundle path and make sure validation passes:

   ```bash
   make validate-rung-bc-evidence EVIDENCE_DIR=<bundle>
   ```

7. Review `rung-bc-proof-summary.tsv`, pod describe/events, Trustee logs, and mirror logs. Rung
   b/c should not be called complete unless happy pods run and negative pods fail closed with the
   expected denial signals. Current rig evidence shows rung-c policy enforcement passes. Current
   rung-b evidence shows direct pods fail before guest pull, and a diagnostic guest-pull path reaches
   KBS but fails layer decryption.

8. Replay on a fresh node or freshly recreated disposable rig. Production sign-off requires replay after regenerating hardware-bound values such as VCEKs, RVPS, Trustee URL/TLS, initdata, image keys, and signing trust material.

9. Move PR #8 out of draft only after rig evidence is attached or referenced, CI/checks are green, Copilot or equivalent machine review has no blocking findings, and `make lint` remains green.

## Current blocker

Rig access is confirmed. Rung-c is functionally proven for signed-image policy acceptance and
unsigned-image denial, with pod-status app-start validation covering the empty-log behavior seen on
the rig. Rung-b completion remains blocked on two items: direct CRI-O/Kata pods need a supported way
past the host encrypted-layer pre-pull, and the diagnostic guest-pull path must be made to decrypt
successfully after Trustee releases `image-kek/<uuid>`.
