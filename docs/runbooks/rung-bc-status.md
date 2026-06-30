# Rung b/c status

Last updated: 2026-06-30T09:07:58Z

Current PR: #8, `codex/rung-bc-support`
Latest pushed proof-tooling checkpoint verified on the rig before this source-analysis note: `9f2ea25`
Status: repo scaffolding and local no-hardware validation are green; live rig access is confirmed.
Rung-c now has live happy-path and unsigned-control denial evidence, and offline validation accepts
pod-status app-start evidence when CC logs are empty. Rung-b is not complete. Direct digest/tag
pods are still blocked by CRI-O host-side encrypted-layer pre-pull before guest pull begins. The
separate guest decryption blocker is diagnosed: the current image's wrapped layer key decrypts with
`/home/rocky/rung-b/kek.bin`, not the previously recorded `/home/rocky/rung-b/image-kek.bin`.
A follow-up CRI-O `default_annotations` probe also failed to redirect the Kata guest-pull source
away from the already-present carrier image. Disabling CRI-O's configured host decryption key path
also did not change the direct digest failure. The measured-initdata policy mechanics are now
diagnosed in the tag-shaped diagnostic path: a resource policy must read
`input.submods[*]["ear.trustworthiness-vector"].configuration`, and this OSC/SNP stack exposes
the live HOST_DATA claim as the SHA-256 `input.init_data` value from the initdata TOML
`algorithm`, not the SHA-384 `init_data` value emitted by Veritas for the same TOML. With a
temporary SHA-256 literal EAR policy, the happy diagnostic pod received `image-kek` and reached
`Running`, while the tampered-initdata diagnostic pod received `image-kek` 401/`PolicyDeny` and
stayed `CreateContainerError`. This proves the intended key-release gate can be made selective,
and `scripts/render-rung-b-measurement-policy.sh` now renders that policy pair from a rendered
initdata file. The result is still diagnostic only until it is paired with a direct digest-pinned
encrypted-image path. The remaining CRI-O direct-pull blocker is tracked upstream in
<https://github.com/cri-o/cri-o/issues/10084>.

## What is already in place

- Rung-b and rung-c build, seed, apply, negative-test, collect, validate, and one-shot proof targets exist.
- Proof runs require digest-pinned image refs; tag-only proof refs are rejected before apply.
- Rung-b evidence tracks encrypted image key ID, initdata policy URI, Trustee resource fetches, mirror pulls, pod state, app-start evidence, and fail-closed tampered-initdata behavior.
- Rung-c evidence tracks signed image policy URI, public key resource fetch, mirror pulls, pod state, app-start evidence, and fail-closed unsigned-image behavior.
- Final rung-b/c evidence validation now requires mirror-log lines showing guest `oci-client`
  manifest pulls for the expected rung-b, rung-c signed, and rung-c unsigned digest refs, plus
  guest `oci-client` blob pulls for the rung-b and rung-c happy-image repositories. Host-only CRI-O
  pulls or manifest-only happy pulls cannot satisfy the guest-pull proof invariant.
- Final validation also requires bounded CRI-O node logs showing the `image_guest_pull` source
  for each expected digest ref, so carrier-image or stale-source runs cannot satisfy the
  digest-pinned proof invariant.
- Evidence bundles record non-secret provenance in `summary.env`, including repo revision, branch, dirty state, KBS URL, policy URIs, pod role names, and app log markers.
- `make prove-rung-bc` now records the proof start time and collects Trustee, CRI-O, and mirror
  logs with proof-window bounds. Final validation rejects unbounded Trustee, CRI-O, or mirror
  logs so stale KBS resource fetches, stale CRI-O sources, or stale registry pulls cannot satisfy
  key/policy or guest-pull checks.
- Offline validation derives expected KBS resource log entries from the recorded rung-b key ID and rung-c policy URI, so custom KBS paths are validated against the actual run configuration.
- Trustee seeding now derives the rung-b Secret resource/key from `RUNG_B_KEY_ID`, so a
  keyprovider-generated URI such as `kbs:///default/image-kek/<uuid>` can be seeded and
  fingerprinted instead of forcing every proof into `image-key/rung-b`.
- Initdata encoding now uses deterministic gzip output, and evidence validation compares decoded
  initdata content for happy/negative relationships so gzip metadata cannot create false
  differences.
- The rung-b negative-test harness now rejects host-side encrypted-layer pull failures as proof
  signals; it requires an attestation, measurement, authorization, or KBS resource-denial signal
  instead of accepting a generic `decrypt` message, and it scopes Trustee logs to the current
  probe so stale denials from older pods cannot satisfy a new negative test.
  A live rig run against the current direct digest failure now exits non-zero with
  `no rung-b attestation/image-key denial signal`, as intended.
- `make diagnose-rung-b-direct-pull` now renders the direct digest-pinned rung-b pod, waits for
  the known host-side encrypted-layer blocker, and writes an issue-ready evidence directory with
  pod, event, Trustee, CRI-O, and mirror context. It exits zero only when the blocker appears
  before any Trustee image-key request.
- `make validate-rung-b-direct-pull DIAG_DIR=<bundle>` now validates those direct-pull diagnostic
  bundles offline, including known-blocker classification, no Trustee image-key request, and the
  compact mirror-count shape when `mirror/summary.tsv` is present. Current diagnostic bundles also
  record bounded mirror-log collection in `summary.env`; the Make target forwards
  `REQUIRE_MIRROR_SUMMARY=0` explicitly for older bundles collected before mirror summaries
  existed, and current bundles should keep the strict default.
- `scripts/gen-rvps-veritas.sh` now matches the live Veritas behavior seen on the rig:
  it passes `--ocp-version`, defaults to the pinned `coco-tools` digest used by VCEK collection,
  treats Veritas `-o` as an output directory, supports a cached `oc debug` image, and can stage a
  temporary `VERITAS_OC_WRAPPER` for disconnected release-image mirror rewrites.

## Local verification completed

The following no-hardware checks passed on 2026-06-30:

```bash
bash -n scripts/apply-rung-image.sh scripts/collect-rung-bc-evidence.sh scripts/negative-test.sh scripts/prove-rung-bc.sh scripts/validate-rung-bc-evidence.sh scripts/verify-rung-bc-render.sh
shellcheck scripts/apply-rung-image.sh scripts/collect-rung-bc-evidence.sh scripts/negative-test.sh scripts/prove-rung-bc.sh scripts/validate-rung-bc-evidence.sh scripts/verify-rung-bc-render.sh
git diff --check
bash scripts/verify-rung-bc-render.sh
make lint
```

The updated validator was also run from this checkout against the older rig bundle
`/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/evidence-20260630T023159Z`; it correctly exits
non-zero with thirteen promotion-gate issues, including missing Trustee, CRI-O, and mirror log
proof-window metadata, missing CRI-O source logs, plus the known rung-b guest-pull gaps.

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
- Final evidence bundle for this pass: `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/evidence-20260630T023159Z` on the bastion. With the current validator, this bundle passes the rung-c happy pod, pod-status app-start, same decoded initdata, Trustee fetch, unsigned image, `oci-client` guest manifest/blob pull, and denial checks. It still exits non-zero on eleven promotion-gate items: missing Trustee log `--since-time` window in this older bundle, missing mirror log `--since-time` window in this older bundle, missing rung-b negative image proof-summary row, happy pod Pending, app container not started, missing rung-b negative pod, missing rung-b decoded negative relationship, missing rung-b negative decoded initdata, missing Trustee fetch for `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`, missing guest `oci-client` manifest pull for the rung-b digest, and missing guest `oci-client` blob pull for the rung-b repository. `oc exec` into the rung-c pod remains blocked by policy.
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
- The decryption mismatch was then isolated offline without printing key material:
  - `mirror.rig.local:8443/coco/rung-b:encrypted` and the digest ref both resolve to
    `sha256:69b8fa1c66919ff9d4412fc6ecd0139aa78883c93fdfc78db0aecd526de0890c`.
  - The layer provider annotation KID is
    `kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`.
  - `/home/rocky/rung-b/image-kek.bin` and the Trustee Secret originally matched each other
    (`sha256:8cc0cb80012c4a5e1fb618b161fc36d3010be49eddb1a85108775bb5d5aace4b`), but that key
    failed to unwrap the layer key.
  - `/home/rocky/rung-b/kek.bin`
    (`sha256:f85822d4f55b41ed4f915a541a68aa41dece5944db73c269aff292a78fe6684c`) successfully
    unwrapped the layer key. The trailing 32 bytes of `/home/rocky/rung-b/kek_capture` match this
    same key.
- Trustee was reseeded at the existing KID with `/home/rocky/rung-b/kek.bin`; the Secret now has
  length 32 and SHA-256 `f85822d4f55b41ed4f915a541a68aa41dece5944db73c269aff292a78fe6684c`.
  The bastion's generated `rung-bc.env` and `rung-bc-images.json` were updated to record that key
  file/SHA, with timestamped `.before-correct-kek-*` backups left in `rung-bc-artifacts/`.
- Re-running the local-storage alias diagnostic after reseeding Trustee succeeded:
  - Pod `rung-b-local-alias-fixed-key` reached `Running` and `Ready`.
  - Trustee logs showed HTTP 200 responses for
    `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c` from the diagnostic pod IP.
  - CRI-O logged `image_guest_pull mirror.rig.local:8443/coco/rung-b:encrypted`, then
    `Created container` and `Started container` for the app.
  - The temporary pod and local alias were removed; CRI-O config remained restored and the node
    stayed Ready.
- A controlled tag diagnostic re-confirmed the useful part of that result and exposed the next
  negative-test blocker:
  - With the host carrying only a temporary local alias from the unencrypted carrier image to
    `mirror.rig.local:8443/coco/rung-b:encrypted`, a tag-shaped rung-b pod reached `Running`.
    CRI-O logged `image_guest_pull mirror.rig.local:8443/coco/rung-b:encrypted`, and Trustee
    served `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c` with HTTP 200.
  - A second tag-shaped pod with tampered measured initdata also reached `Running` and fetched the
    same image key with HTTP 200. Live Trustee config still had empty
    `rvps-reference-values`, `resource-policy` set to `default allow := true`, and an
    attestation policy that affirms all EAR trust claims. That means measured-initdata mismatch is
    not currently enforced on the rig.
  - The temporary pods and local tag alias were removed; the node stayed Ready.
- Veritas RVPS generation for the current rung-b initdata is now reproducible on the rig:
  - Current initdata: `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rvps-probe-20260630T045611Z/rung-b-initdata.toml`
    (`sha256:a6ae0bdf358463ff272bba868c06c33a80c0b5a6678fac3936dbd66ab27efae0`).
  - Direct `veritas --platform baremetal --tee snp` requires `--ocp-version`; without it,
    Veritas exits with `At least one --ocp-version is required for baremetal`.
  - In this disconnected rig, Veritas hard-codes
    `quay.io/openshift-release-dev/ocp-release:<version>-x86_64` through `oc adm release info`.
    Mounting `/etc/containers/registries.conf` is not enough for that path: tag-shaped release
    refs ignore IDMS, and public `quay.io` is unreachable.
  - A temporary `oc` wrapper rewrote the hard-coded release tag to
    `mirror.rig.local:8443/openshift/release-images:4.20.18-x86_64`, rewrote the extracted
    `rhel-coreos-extensions` image to `mirror.rig.local:8443/openshift/release@sha256:109247...`,
    and skipped Veritas's upstream `--verify` component scan after proving the mirror release tag
    was readable. This is a disconnected-rig workaround, not a substitute for mirror provenance.
  - Running the patched script with that wrapper and the bastion Docker auth file produced
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rvps-probe-20260630T045611Z/veritas-rung-b-rvps-script.yaml`
    with `sha256:f80ced520abeabbe823bc9f9e7afc05a7ed657951a7d82befc6990dc51aa307f`.
    The artifact is a `rvps-reference-values` ConfigMap containing 96
    `snp_launch_measurement` values and one `init_data` value.
  - The generated RVPS was inspected but not applied as a sign-off baseline. Live Trustee still
    has `resource-policy: default allow := true` and an EAR policy that affirms every trust claim,
    so measured-initdata negatives remain invalid until policy is tightened too.
- A follow-up policy probe converted the permissive measured-initdata finding into a scoped
  diagnostic pass/fail result:
  - A resource policy checking `input["submods"][sm]["ear.status.configuration"] == 2`, even for
    all submodule names, denied the happy pod. Trustee EAR tokens expose the numeric AR4SI value at
    `input["submods"][sm]["ear.trustworthiness-vector"]["configuration"]`; `ear.status` is a
    string status, not the numeric vector.
  - With the corrected resource policy and an unconditional EAR `configuration := 2`, the
    tag-shaped happy pod reached `Running` and Trustee served
    `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c` with HTTP 200.
    Artifact: `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/policy-probe-20260630T055938Z-resource-tv`.
  - The rendered happy initdata file still matched the Veritas input exactly:
    SHA-256 `a6ae0bdf358463ff272bba868c06c33a80c0b5a6678fac3936dbd66ab27efae0`,
    SHA-384 `e85af2d3a78cb298bb2838560567d726f9af503fd9606c35b0be6d233a836d797e5053b70c7aef7ed25601417bb29ae0`.
    However, `input.init_data in query_reference_value("init_data")` and literal checks against
    the SHA-384 or its base64 encoding denied the happy pod. Source inspection explains the
    mismatch: for SNP, Trustee verifies HOST_DATA from the initdata TOML hash algorithm and
    exposes the report's 32-byte HOST_DATA as `input.init_data`.
  - A temporary EAR policy using the SHA-256 HOST_DATA literal made the tag-shaped happy pod reach
    `Running` with `image-kek` HTTP 200. Artifact:
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/policy-probe-20260630T061331Z-initdata-sha256`.
  - The same policy denied the tag-shaped tampered-initdata pod: it stayed
    `CreateContainerError`, Trustee returned repeated `PolicyDeny`/HTTP 401 for the same
    `image-kek` resource, and the pod never became Ready. Artifact:
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/policy-probe-20260630T061409Z-tampered-sha256`.
  - The rig was restored afterward: `rvps-reference-values` back to `[]`, `resource-policy` back
    to `default allow := true`, diagnostic pods deleted, local `coco/rung-b:encrypted` alias
    removed, and `sno-coco-node` Ready.
- Source inspection and additional pre-stage probes explain why direct digest refs still fail:
  - CRI-O `runtime_pull_image` adds Kata's `image_guest_pull` virtual volume only during
    `CreateContainer`, after CRI-O has already resolved the container image from local storage.
    It populates `io.kubernetes.cri-o.ImageName` from that local image status result, so a
    pod-supplied annotation cannot override the guest-pull source.
  - CRI-O `PullImage` always passes a non-nil ocicrypt decrypt config from
    `decryption_keys_path`; for the encrypted digest ref, containers/image tries to decrypt the
    layer and aborts because digest-preserving destinations cannot accept the modified manifest.
  - Pre-staging the actual encrypted image into node `containers-storage` with `skopeo copy
    --preserve-digests` failed because the encrypted blob digest does not match the image config
    DiffID expected by containers/storage.
  - Trying to tag the carrier image with the encrypted digest failed with `tag by digest not
    supported`. Only a tag-shaped carrier alias is possible on this stack, and that remains a
    diagnostic path rather than a digest-pinned production proof.
  - A safer storage-aware carrier-alias probe also failed: `crictl inspecti` confirms the carrier
    image is present under rung-c/rung-c-unsigned canonical digest names, but not under the rung-b
    encrypted digest; `podman tag <carrier> mirror.rig.local:8443/coco/rung-b@sha256:69b8...`
    still rejects tag-by-digest; and `skopeo copy containers-storage:<carrier-digest>
    containers-storage:<encrypted-digest>` refuses the copy because the carrier manifest digest
    would not match the encrypted destination digest.
- The packaged direct-pull diagnostic bundle
  `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T085844Z` validates
  with `make validate-rung-b-direct-pull DIAG_DIR=...` on the bastion. The validation confirms the
  known host-pull blocker, digest-pinned rung-b image, no Trustee image-key request, bounded
  mirror-log collection from `2026-06-30T08:58:44Z`, CRI-O rung-b manifest/blob pulls in the
  mirror log summary, and zero guest `oci-client` rung-b pulls.
  - The containerd-style annotation key `io.kubernetes.cri.image-name` cannot be added through
    CRI-O runtime `allowed_annotations`; it is not in CRI-O's `AllAllowedAnnotations` table.
    Runtime-level `default_annotations` did accept
    `io.kubernetes.cri.container-type=container` and `io.kubernetes.cri.image-name=<encrypted
    digest>`, but a live probe still emitted Kata `image_guest_pull` for the carrier digest,
    reached `Running` as the carrier, and made no `image-kek` KBS request. The temporary config
    was restored and the node returned Ready.
  - After CRI-O restarts on this air-gapped rig, `oc debug node` should use a cached mirror image
    such as `mirror.rig.local:8443/coco/rung-c-unsigned@sha256:4ba374...`; the default
    `registry.redhat.io/rhel9/support-tools` image can time out before the restore command runs.
  - Temporarily adding a CRI-O drop-in with `[crio.runtime] decryption_keys_path = ""`,
    restarting CRI-O, and recreating the direct digest pod did not change the failure. The pod
    still reported layer `sha256:346e9...` should be decrypted but the manifest could not be
    modified because the destination specifies a digest; Trustee logs still had no `image-kek`
    request. The drop-in was removed, CRI-O was restarted, the node returned Ready, and no rung-b
    image remained in node storage.
  - The new `make diagnose-rung-b-direct-pull` helper was verified on the rig at
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T070116Z`.
    It reproduced `classification=known-host-pull-blocker` for
    `rung-b-direct-pull-diag`: pod phase `Pending`, `host_pull_blocker_seen=1`, and
    `image_key_request_seen=0`. The helper removed the diagnostic pod afterward; the node
    remained Ready and no debug pods were left behind.
  - After the helper gained mirror-log capture, it was rerun on the rig at
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T072254Z`.
    It again reproduced `classification=known-host-pull-blocker`: pod phase `Pending`,
    `host_pull_blocker_seen=1`, and `image_key_request_seen=0`. The new mirror context includes
    `quay-app.log`, nginx access logs, and registry-side proof that `cri-o/1.33.10` pulled
    `coco/rung-b` manifest
    `sha256:69b8fa1c66919ff9d4412fc6ecd0139aa78883c93fdfc78db0aecd526de0890c` plus encrypted
    layer `sha256:346e9fd547e142e6a12881b64a7977640e6f9ca68c20da538f8a523e17de87f7` before any
    Trustee `image-kek` request appeared. The helper removed the diagnostic pod afterward; the
    node remained Ready and no debug pods were left behind.
  - After the helper gained `mirror/summary.tsv`, it was rerun at
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T073223Z`.
    It again reproduced `classification=known-host-pull-blocker`: pod phase `Pending`,
    `host_pull_blocker_seen=1`, and `image_key_request_seen=0`. The new compact mirror summary
    counted `crio_rung_b_manifest=16`, `crio_rung_b_blob=16`, `guest_rung_b_manifest=0`, and
    `guest_rung_b_blob=0`, confirming the host CRI-O path repeatedly pulled the rung-b manifest
    and encrypted blob while the guest `oci-client` never pulled the rung-b image. The helper
    removed the diagnostic pod afterward; the node remained Ready and no debug pods were left
    behind.
  - After fixing diagnostic command output packaging and adding the offline validator, it was
    rerun at
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T074842Z`.
    The diagnostic again reproduced `classification=known-host-pull-blocker`: pod phase
    `Pending`, `host_pull_blocker_seen=1`, `image_key_request_seen=0`,
    `crio_rung_b_manifest=16`, `crio_rung_b_blob=16`, `guest_rung_b_manifest=0`, and
    `guest_rung_b_blob=0`. The bundle now contains command outputs such as `cluster-info.txt`,
    `runtimeclass-kata-cc.yaml`, `pod.json`, `events.txt`, `trustee.log`, and `crio-node.log`
    inside the diagnostic directory instead of leaking them into the checkout root. Running
    `make validate-rung-b-direct-pull DIAG_DIR=/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T074842Z`
    passed. The helper removed the diagnostic pod afterward; the node remained Ready and no debug
    pods were left behind.
  - After bounding direct-pull diagnostic mirror logs to the diagnostic start time, it was rerun
    at
    `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T085844Z`.
    The diagnostic again reproduced `classification=known-host-pull-blocker`: pod phase
    `Pending`, `host_pull_blocker_seen=1`, `image_key_request_seen=0`,
    `mirror_log_since_time=2026-06-30T08:58:44Z`, `crio_rung_b_manifest=16`,
    `crio_rung_b_blob=16`, `guest_rung_b_manifest=0`, and `guest_rung_b_blob=0`.
    Running
    `make validate-rung-b-direct-pull DIAG_DIR=/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T085844Z`
    passed with the strict default mirror-summary requirement. The helper removed the diagnostic
    pod afterward; the node remained Ready and no debug pods were left behind.
- NRI was inspected as a possible late guest-pull-source override:
  - CRI-O 1.33 calls NRI `CreateContainer` after creating the local image result and before saving
    the final OCI spec/runtime create. The NRI runtime-tools generator can adjust annotations, so
    it is late enough to affect Kata's `image_guest_pull` annotation source.
  - CRI-O filters NRI-adjusted annotations through runtime `allowed_annotations`, so changing
    `io.kubernetes.cri-o.ImageName` would still require a temporary CRI-O allow-list entry.
  - On the rig, `/var/run/nri/nri.sock` exists, but `/opt/nri`, `/etc/nri`, and
    `/usr/libexec/nri` do not contain reusable plugin files. The live `kata-snp` runtime still
    allows only `io.kubernetes.cri-o.Devices`.
  - NRI cannot prevent the original direct encrypted digest from failing in CRI-O host image
    status/pull before `CreateContainer`; at most it could diagnose a local carrier-image path by
    changing the later guest-pull source. That remains custom mechanism work, not current rung-b
    proof.
- A source recheck of CRI-O `release-1.33` and `main`, plus Kata main, still points to the same
  ordering: CRI-O's `PullImage` path supplies an ocicrypt decrypt config before storage import,
  `CreateContainer` resolves a local image result and writes `io.kubernetes.cri-o.ImageName` from
  `ImageResult.SomeNameOfThisImage`, and only then does `runtimeVM.CreateContainer` use that
  annotation as the Kata `image_guest_pull` source. CRI-O main's annotation constant explicitly
  says `ImageName` has no relationship to the user input used to find the image, so the source path
  matches the carrier/default-annotation probe results: there is not an existing config knob here
  that preserves the user-requested encrypted digest as the guest-pull source while bypassing the
  host encrypted-layer pull.

1. Find a supported OpenShift/CRI-O path that gets direct rung-b pods to `CreateContainer` without
   host-side encrypted-layer pre-pull. The diagnostic local alias, CRI-O annotation probes, and
   host-decryption-key-path probe are useful for root-cause work, but they are not production proof
   paths. A custom NRI probe is now source-plausible only as a carrier-path diagnostic; it cannot
   close rung b unless it becomes a supported path that preserves digest-pinned proof inputs. The
   upstream issue is <https://github.com/cri-o/cri-o/issues/10084>, and the repo-local escalation
   packet is in `docs/runbooks/rung-b-upstream-escalation.md`.

2. Replay the restrictive measured-initdata policy with the next viable direct encrypted-image
   path before counting rung-b negatives. RVPS generation now works for the current rung-b initdata,
   but its `init_data` value is the
   SHA-384 of the TOML, while this SNP/OSC path gates HOST_DATA through the SHA-256
   `input.init_data` claim because the initdata TOML declares `algorithm = "sha256"`. The
   renderer now emits the SHA-256 literal and a resource policy keyed on
   `ear.trustworthiness-vector.configuration`; use it for the proof window and restore the
   permissive baseline afterward.

3. If the rung-b image is rebuilt, rerun the offline unwrap check before seeding Trustee:

   - Decode the encrypted layer annotation for the new digest.
   - Confirm it references the intended KID.
   - Confirm the Trustee Secret data is byte-for-byte the KEK that unwraps the layer key.

4. Build and push any rebuilt rung-b encrypted image and rung-c signed plus unsigned-control images on the bastion or connected host:

   ```bash
   COSIGN_PASSWORD='<secret>' make build-rung-images
   . rung-bc-artifacts/rung-bc.env
   ```

5. Seed Trustee with the rung-b image key, rung-c public key, and rung-c signed-image policy, then reconcile Trustee:

   ```bash
   make apply-trustee-rung-bc \
     RUNG_B_KEY_FILE=rung-bc-artifacts/rung-b-image.key \
     RUNG_C_COSIGN_PUB=rung-bc-artifacts/cosign.pub
   ```

6. Run the hardware proof on the disposable rig:

   ```bash
   make prove-rung-bc
   ```

7. Keep the generated evidence bundle path and make sure validation passes:

   ```bash
   make validate-rung-bc-evidence EVIDENCE_DIR=<bundle>
   ```

8. Review `rung-bc-proof-summary.tsv`, pod describe/events, Trustee logs, and mirror logs. Rung
   b/c should not be called complete unless happy pods run and negative pods fail closed with the
   expected denial signals. Current rig evidence shows rung-c policy enforcement passes. Current
   rung-b evidence shows direct pods fail before guest pull. A diagnostic carrier-tag guest-pull
   path reaches KBS and starts after the Trustee key correction, but it is not a digest-pinned
   production proof.

9. Replay on a fresh node or freshly recreated disposable rig. Production sign-off requires replay after regenerating hardware-bound values such as VCEKs, RVPS, Trustee URL/TLS, initdata, image keys, and signing trust material.

10. Move PR #8 out of draft only after rig evidence is attached or referenced, CI/checks are green, Copilot or equivalent machine review has no blocking findings, and `make lint` remains green.

## Current blocker

Rig access is confirmed. Rung-c is functionally proven for signed-image policy acceptance and
unsigned-image denial, with pod-status app-start validation covering the empty-log behavior seen on
the rig. Rung-b completion remains blocked on the direct CRI-O/Kata path: the production proof still
needs a supported way past host encrypted-layer pre-pull so the real digest-pinned pod, not the
diagnostic local alias or carrier/default-annotation probe, reaches guest pull. Source inspection
indicates CRI-O 1.33 performs the host image pull/status work before Kata's guest-pull handoff,
node containers-storage cannot hold the encrypted OCI layer unchanged for a digest-pinned
`IfNotPresent` bypass, and CRI-O annotation/default-annotation routes do not override the app
image source that Kata receives. Overriding CRI-O's host decryption key path to an empty value did
not change that ordering or move the pull into the guest. The rig Trustee baseline is restored to
permissive after probes, but the restrictive measured-initdata policy renderer has been proven in a
tag-shaped diagnostic and should be replayed when a direct encrypted-image path is available. The
direct-pull blocker is tracked upstream in <https://github.com/cri-o/cri-o/issues/10084>.
