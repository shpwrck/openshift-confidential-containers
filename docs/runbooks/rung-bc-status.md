# Rung b/c status

Last updated: 2026-06-30T02:44:34Z

Current PR: #8, `codex/rung-bc-support`
Current head before this update: `132ca0b`
Status: repo scaffolding and local no-hardware validation are green; live rig access is confirmed. Rung-c now has live happy-path and unsigned-control denial evidence, and offline validation accepts pod-status app-start evidence when CC logs are empty. Rung-b is still blocked by CRI-O host-side encrypted-layer pre-pull before the guest can fetch the KBS key.

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

1. Build and push the rung-b encrypted image and rung-c signed plus unsigned-control images on the bastion or connected host:

   ```bash
   COSIGN_PASSWORD='<secret>' make build-rung-images
   . rung-bc-artifacts/rung-bc.env
   ```

2. Seed Trustee with the rung-b image key, rung-c public key, and rung-c signed-image policy, then reconcile Trustee:

   ```bash
   make apply-trustee-rung-bc \
     RUNG_B_KEY_FILE=rung-bc-artifacts/rung-b-image.key \
     RUNG_C_COSIGN_PUB=rung-bc-artifacts/cosign.pub
   ```

3. Run the hardware proof on the disposable rig:

   ```bash
   make prove-rung-bc
   ```

4. Keep the generated evidence bundle path and make sure validation passes:

   ```bash
   make validate-rung-bc-evidence EVIDENCE_DIR=<bundle>
   ```

5. Review `rung-bc-proof-summary.tsv`, pod describe/events, Trustee logs, and mirror logs. Rung b/c should not be called complete unless happy pods run and negative pods fail closed with the expected denial signals. Current rig evidence shows rung-c policy enforcement passes, while rung-b still cannot reach the guest/KBS key-release path because CRI-O fails the encrypted-layer pre-pull first.

6. Replay on a fresh node or freshly recreated disposable rig. Production sign-off requires replay after regenerating hardware-bound values such as VCEKs, RVPS, Trustee URL/TLS, initdata, image keys, and signing trust material.

7. Move PR #8 out of draft only after rig evidence is attached or referenced, CI/checks are green, Copilot or equivalent machine review has no blocking findings, and `make lint` remains green.

## Current blocker

Rig access is confirmed. Rung-c is functionally proven for signed-image policy acceptance and unsigned-image denial, with pod-status app-start validation covering the empty-log behavior seen on the rig. Rung-b completion remains blocked on CRI-O host-side pre-pull: the host cannot create a guest-pull placeholder for encrypted layers and fails before the guest can request `image-kek/<uuid>` from KBS.
