# Rung b/c status

Last updated: 2026-06-30T01:44:56Z

Current PR: #8, `codex/rung-bc-support`
Current head: `49f25a4`
Status: repo scaffolding and local no-hardware validation are green; hardware proof is still pending.

## What is already in place

- Rung-b and rung-c build, seed, apply, negative-test, collect, validate, and one-shot proof targets exist.
- Proof runs require digest-pinned image refs; tag-only proof refs are rejected before apply.
- Rung-b evidence tracks encrypted image key ID, initdata policy URI, Trustee resource fetches, mirror pulls, pod state, app-start marker, and fail-closed tampered-initdata behavior.
- Rung-c evidence tracks signed image policy URI, public key resource fetch, mirror pulls, pod state, app-start marker, and fail-closed unsigned-image behavior.
- Evidence bundles record non-secret provenance in `summary.env`, including repo revision, branch, dirty state, KBS URL, policy URIs, pod role names, and app log markers.
- Offline validation derives expected KBS resource log entries from the recorded rung-b key ID and rung-c policy URI, so custom KBS paths are validated against the actual run configuration.

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

5. Review `rung-bc-proof-summary.tsv`, pod describe/events, Trustee logs, and mirror logs. Rung b/c should not be called complete unless happy pods run and negative pods fail closed with the expected denial signals.

6. Replay on a fresh node or freshly recreated disposable rig. Production sign-off requires replay after regenerating hardware-bound values such as VCEKs, RVPS, Trustee URL/TLS, initdata, image keys, and signing trust material.

7. Move PR #8 out of draft only after rig evidence is attached or referenced, CI/checks are green, Copilot or equivalent machine review has no blocking findings, and `make lint` remains green.

## Current blocker

No local code blocker remains. Completion is blocked on access to the target rig or bastion path that can build/push the image artifacts, seed live Trustee resources, and run the actual SEV-SNP confidential workload proofs.
