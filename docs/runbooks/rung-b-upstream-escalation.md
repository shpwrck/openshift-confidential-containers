# Rung b upstream escalation packet

Last updated: 2026-06-30T13:13:24Z

This packet is the upstream summary for the remaining rung-b blocker. It is meant for a CRI-O,
OpenShift sandboxed containers, Kata, or Confidential Containers maintainer without requiring them
to read the whole engagement runbook first.

Upstream issue: <https://github.com/cri-o/cri-o/issues/10084>. As of
`2026-06-30T13:07:58Z`, the issue is closed without a visible maintainer comment or technical
resolution in the timeline; the local evidence still treats the direct-pull path as blocked.

## Short version

On OpenShift 4.20.18 with CRI-O 1.33.10 and Kata 3.25.0, `runtime_pull_image = true` does not let
a digest-pinned encrypted OCI image reach the guest pull path. Kubelet/CRI-O fails the pod during
host-side image pull before `CreateContainer`, so Kata never gets to pull the encrypted image in
guest and Trustee never sees the image-key request.

The same encrypted image can be pulled and decrypted in guest when a local tag-shaped carrier alias
bypasses the host pull, and Trustee can be configured to release the key only for the expected
measured initdata. The remaining gap is specifically the direct, digest-pinned production path.

## Why this matters

The proof invariant for rung b is:

1. The workload pod uses a digest-pinned encrypted image reference.
2. The host does not need the image decryption key.
3. Kata/CoCo pulls the encrypted image inside the guest.
4. Trustee releases the image key only after attestation and measured-initdata policy succeed.
5. A tampered measured-initdata pod fails closed before the image key is released.

Current CRI-O behavior blocks item 3 before the guest can participate.

## Environment

| Component | Observed value |
|---|---|
| OpenShift | 4.20.18 |
| RuntimeClass | `kata-cc` |
| Node | `sno-coco-node` |
| CRI-O | `1.33.10-2.rhaos4.20.gita4d0894.el9` |
| Kata | `3.25.0`, commit `08fad9e2f9516425efbe62a317c8ada7af125b9b` |
| CRI-O runtime config | `/etc/crio/crio.conf.d/50-kata-snp` has `runtime_type = "vm"` and `runtime_pull_image = true` |
| CRI-O `kata-snp` allowed annotations | `io.kubernetes.cri-o.Devices` |
| Encrypted image | `mirror.rig.local:8443/coco/rung-b@sha256:69b8fa1c66919ff9d4412fc6ecd0139aa78883c93fdfc78db0aecd526de0890c` |
| Encrypted layer KID | `kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c` |

## Minimal reproducer

Render and apply the normal rung-b pod with the digest-pinned encrypted image:

```bash
. rung-bc-artifacts/rung-bc.env
make apply-rung-b RUNG_B_IMAGE="$RUNG_B_IMAGE"
```

To collect an issue-ready evidence directory for this exact failure:

```bash
. rung-bc-artifacts/rung-bc.env
make diagnose-rung-b-direct-pull RUNG_B_IMAGE="$RUNG_B_IMAGE"
```

The diagnostic exits zero only when it sees the known host-side encrypted-layer blocker before any
Trustee image-key request. It writes pod, event, Trustee, CRI-O, and mirror-log context under
`rung-bc-artifacts/rung-b-direct-pull-<timestamp>/`. CRI-O node-log and mirror-log capture are
bounded to the diagnostic start time and recorded as `crio_log_since_time` and
`mirror_log_since_time` in `summary.env`. The generated `mirror/summary.tsv` and `summary.env`
count rung-b manifest/blob pulls by `cri-o` and by the guest `oci-client`, which is the quickest
way to see whether the host pulled encrypted content before the guest path started. Current
bundles also copy `rung-bc-images.json` and `rung-bc.env` so the offline validator can prove the
tested digest and KBS key ID match the generated artifact handoff.
Validate a collected bundle before sharing it:

```bash
make validate-rung-b-direct-pull DIAG_DIR=rung-bc-artifacts/rung-b-direct-pull-<timestamp>
```

For older diagnostic bundles collected before artifact/env handoff, `mirror/summary.tsv`, and
current log-window metadata existed, set `REQUIRE_MIRROR_SUMMARY=0` while validating; current
bundles should keep the default strict artifact, summary, and log-window requirements.

Latest validated bounded diagnostic bundle:

- Path: `/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T125624Z`
- Validator: `make validate-rung-b-direct-pull DIAG_DIR=/home/rocky/occ-rung-bc-proof/rung-bc-artifacts/rung-b-direct-pull-20260630T125624Z`
- Result: passed with the strict default artifact-manifest, env-handoff, repo-provenance,
  CRI-O host-pull, log-window, and mirror-summary requirements.
- Key values:
  - `classification=known-host-pull-blocker`
  - `image_key_request_seen=0`
  - validator checkout head `433651a`
  - `repo_git_head=dfae54615e8eee3e22b7209da1c8b3714dceda63`
  - `repo_git_dirty=false`
  - `crio_log_since_time=2026-06-30T12:56:24Z`
  - `mirror_log_since_time=2026-06-30T12:56:24Z`
  - `rung-bc-images.json` matches the diagnostic rung-b digest ref and KBS key ID
  - `rung-bc.env` matches the diagnostic rung-b digest ref and KBS key ID
  - `crio_rung_b_manifest=16`
  - `crio_rung_b_blob=16`
  - `guest_rung_b_manifest=0`
  - `guest_rung_b_blob=0`

Expected behavior:

- CRI-O/Kata should create the VM-backed container.
- Kata should emit `image_guest_pull` for the encrypted digest ref.
- Trustee should log a request for `resource/default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c`.
- The pod should reach `Running` when attestation and key release succeed.

Observed behavior:

- Pod stays `ImagePullBackOff`.
- Kubelet reports that encrypted layer `sha256:346e9...` should be decrypted but the manifest
  cannot be modified because the destination specifies a digest.
- Trustee logs have no `image-kek` request, so the guest never asks for the key.

The tag-shaped pull also fails before guest when the image is not locally present, but with the
host-side message `missing private key needed for decryption`.

## Why this appears to be CRI-O ordering

Source inspection of CRI-O release-1.33 and CRI-O main shows the same effective ordering. The
2026-06-30T09:07Z recheck did not reveal an existing runtime-handler knob that preserves the
user-requested encrypted digest as the guest-pull source while bypassing host-side encrypted-layer
handling.

- `server/image_pull.go` calls `getDecryptionKeys(s.config.DecryptionKeysPath)` before
  `pullImageCandidate`, so the host image service still enters containers/image encrypted-layer
  handling during `PullImage`.
- `server/container_create.go` calls `resolveAndVerifyContainerImage`, which resolves a local
  image result, then `createStorageContainer`, before `createContainerPlatform` invokes the VM
  runtime.
- `internal/factory/container/container.go` writes `io.kubernetes.cri-o.ImageName` from the local
  `ImageResult.SomeNameOfThisImage`. In CRI-O main, the annotation constant explicitly says this
  value has no relationship to the user input used to find the image.
- `internal/oci/runtime_vm.go` later uses `c.Spec().Annotations[io.kubernetes.cri-o.ImageName]` as
  the Kata `image_guest_pull` source, and `runtime_pull_image` gates only this later
  `CreateContainer` virtual-volume handoff.
- Kata's guest-side code consumes storage entries with driver `image_guest_pull`; it does not
  recover the original CRI image reference if CRI-O has already supplied a carrier/local image name.

Release-1.33 source checked locally at `3c4da7a15593b9e2716bb6c69a3f0ff6f026033f`; CRI-O main was
checked at `ec15c528e4c25dfbf6e52498c8bda3187b62392b`. Relevant upstream files:

- <https://github.com/cri-o/cri-o/blob/release-1.33/server/image_pull.go>
- <https://github.com/cri-o/cri-o/blob/release-1.33/server/container_create.go>
- <https://github.com/cri-o/cri-o/blob/release-1.33/internal/factory/container/container.go>
- <https://github.com/cri-o/cri-o/blob/release-1.33/internal/oci/runtime_vm.go>
- <https://github.com/cri-o/cri-o/blob/main/server/image_pull.go>
- <https://github.com/cri-o/cri-o/blob/main/server/container_create.go>
- <https://github.com/cri-o/cri-o/blob/main/internal/factory/container/container.go>
- <https://github.com/cri-o/cri-o/blob/main/internal/annotations/annotations.go>
- <https://github.com/cri-o/cri-o/blob/main/internal/oci/runtime_vm.go>
- <https://github.com/kata-containers/kata-containers/blob/main/src/agent/src/confidential_data_hub/image.rs>

Targeted issue searches on 2026-06-30 did not find an obvious existing CRI-O or Kata issue for
this exact `runtime_pull_image` plus encrypted digest failure, so
<https://github.com/cri-o/cri-o/issues/10084> was filed with the current rig evidence.

## Workarounds ruled out

| Attempt | Result |
|---|---|
| `experimental_force_guest_pull` pod annotation | Direct digest still failed before any Trustee image-key request. |
| Node-level Kata `experimental_force_guest_pull = true` | Direct digest still failed before any Trustee image-key request. |
| `imagePullPolicy: Never` | Failure changed to `ErrImageNeverPull`; no guest pull. |
| Allow pod annotation `io.kubernetes.cri-o.ImageName` | CRI-O still wrote the create-time image source from the local image result. |
| Runtime `default_annotations` for containerd-style `io.kubernetes.cri.image-name` | Pod ran as the local carrier image; no `image-kek` request. |
| CRI-O `[crio.runtime] decryption_keys_path = ""` | Direct digest still failed with the digest-preserving host decrypt error. |
| Pre-stage encrypted image into `containers-storage` | `skopeo copy --preserve-digests` failed because encrypted blob digest did not match image config DiffID. |
| Tag carrier image as the encrypted digest | `podman tag ... repo@sha256:...` failed with `tag by digest not supported`. |
| Copy carrier image to encrypted digest with `skopeo` | `Digest of source image's manifest would not match destination reference`. |
| NRI `CreateContainer` annotation adjustment | Source-plausible only after local image status succeeds; cannot prevent direct encrypted digest host pull failure before `CreateContainer`. |

## Positive evidence

These findings make the remaining blocker narrower than "encrypted images do not work":

- The same air-gapped CoCo guest-pull path is already proven for a plain digest-pinned image:
  rung-a reaches `Running`, Trustee releases its resources, and the mirror sees the guest
  `oci-client` pull image content over HTTPS.
- The encrypted layer KID is known and the correct 32-byte KEK was identified.
- Trustee reseeded with that KEK can release the key to a guest.
- A local tag-shaped carrier alias can cause Kata to perform an `image_guest_pull` for the real
  encrypted image.
- With the corrected KEK, that tag-shaped diagnostic reaches `Running`.
- A restrictive Trustee policy using SHA-256 HOST_DATA and
  `ear.trustworthiness-vector.configuration` releases `image-kek` for the expected initdata and
  denies a tampered initdata pod with KBS 401/`PolicyDeny`.

## Requested upstream behavior

One of these would unblock rung b:

- For VM runtimes with `runtime_pull_image = true`, CRI-O skips host-side encrypted-layer
  decryption/pull for the user workload image and lets Kata receive the original user-requested
  digest ref as the `image_guest_pull` source.
- Or CRI-O provides a supported way to use a local carrier/rootfs image for host bookkeeping while
  preserving the original digest-pinned encrypted image as the guest-pull source.
- Or OpenShift sandboxed containers documents a supported delivery path for digest-pinned encrypted
  images that does not require the host to possess the image decryption key.

Any candidate fix must preserve the proof invariant: the pod spec and evidence bundle must still
show the encrypted app image as digest-pinned, and a measured-initdata mismatch must deny the image
key before the app starts.
