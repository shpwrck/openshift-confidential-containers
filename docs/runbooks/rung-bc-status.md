# Rung b/c status

Last updated: 2026-06-30T01:58:01Z

Current PR: #8, `codex/rung-bc-support`
Current head before this update: `6cc0af8`
Status: repo scaffolding and local no-hardware validation are green; live rig access is confirmed, but hardware proof is blocked by product/runtime behavior rather than missing local automation.

## What is already in place

- Rung-b and rung-c build, seed, apply, negative-test, collect, validate, and one-shot proof targets exist.
- Proof runs require digest-pinned image refs; tag-only proof refs are rejected before apply.
- Rung-b evidence tracks encrypted image key ID, initdata policy URI, Trustee resource fetches, mirror pulls, pod state, app-start marker, and fail-closed tampered-initdata behavior.
- Rung-c evidence tracks signed image policy URI, public key resource fetch, mirror pulls, pod state, app-start marker, and fail-closed unsigned-image behavior.
- Evidence bundles record non-secret provenance in `summary.env`, including repo revision, branch, dirty state, KBS URL, policy URIs, pod role names, and app log markers.
- Offline validation derives expected KBS resource log entries from the recorded rung-b key ID and rung-c policy URI, so custom KBS paths are validated against the actual run configuration.
- Trustee seeding now derives the rung-b Secret resource/key from `RUNG_B_KEY_ID`, so a
  keyprovider-generated URI such as `kbs:///default/image-kek/<uuid>` can be seeded and
  fingerprinted instead of forcing every proof into `image-key/rung-b`.

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
- The SNO node is Ready and Trustee is running. Current KbsConfig is back at the rung-a baseline and does not include rung-b/c Secret resources until `apply-trustee-rung-bc` is run.
- The existing `ghcr.io/confidential-containers/coco-keyprovider:latest` image on the bastion is a runtime keyprovider server with `/usr/local/bin/coco_keyprovider`; it does not contain the `/encrypt.sh` helper assumed by `make build-rung-images`.
- The bastion mirror rejected source signature attachment writes during `skopeo copy`; the builder now defaults `SKOPEO_COPY_ARGS` to `--remove-signatures`, and rung-c signing still happens after the copy.
- The rung-c unsigned negative-control default now uses `coco/rung-c-unsigned`, not another tag in the signed `coco/rung-c` repository, so repository-scoped cosign signature storage cannot accidentally satisfy the unsigned control.
- Prior rig artifacts under `/home/rocky/rung-b` show encrypted OCI images with `kbs:///default/image-kek/<uuid>` KIDs and 32-byte KEK files. The expected `mirror.rig.local:8443/coco/rung-b` and `coco/rung-c` repos were not present in the mirror at this check.
- Local/private rig notes record that encrypted-image mechanics and signed-image policy delivery were tested on 2026-06-29, but rung-b execution hit CRI-O host-side encrypted-layer pre-pull and rung-c cosign verification hung after signature fetch in the air-gapped guest.

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

5. Review `rung-bc-proof-summary.tsv`, pod describe/events, Trustee logs, and mirror logs. Rung b/c should not be called complete unless happy pods run and negative pods fail closed with the expected denial signals. The current rig evidence suggests this will not pass on OSC 1.12 without resolving the encrypted-image host pre-pull and offline signature-verification transport blockers.

6. Replay on a fresh node or freshly recreated disposable rig. Production sign-off requires replay after regenerating hardware-bound values such as VCEKs, RVPS, Trustee URL/TLS, initdata, image keys, and signing trust material.

7. Move PR #8 out of draft only after rig evidence is attached or referenced, CI/checks are green, Copilot or equivalent machine review has no blocking findings, and `make lint` remains green.

## Current blocker

Rig access is confirmed. Completion is blocked on product/runtime gaps observed on the rig: CRI-O host-side pre-pull cannot create a guest-pull placeholder for encrypted layers, and the current air-gapped signed-image path has not completed offline verification. The repo can now seed and validate the actual generated rung-b KID resource, but the rungs are not complete until those runtime blockers are resolved or a supported workaround is proven end to end.
