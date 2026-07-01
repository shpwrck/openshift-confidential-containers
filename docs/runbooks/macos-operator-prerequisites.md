# macOS operator prerequisites & local-vs-bastion script split

Customer operators drive these runbooks from a stock **macOS** workstation as well as from
Linux. macOS ships a BSD userland and **bash 3.2**, so the repo's operator-local scripts are
written to run there *without* GNU coreutils. This page lists what you need on a Mac and which
scripts run where.

## TL;DR

- You do **not** need `brew install coreutils`. The scripts pick BSD vs GNU tools at runtime
  through a small shim (`scripts/lib/compat.sh`) — `shasum` instead of `sha256sum`,
  `base64 -D` instead of `base64 -d`, and so on.
- The default `/bin/bash` (3.2) is fine — no bash-4-only constructs (`mapfile`, `${x^^}`,
  `declare -A`) are used in operator-local paths.
- Install a handful of CLIs with Homebrew (below).

## Required tools (operator workstation)

| Tool | Install (macOS) | Used by |
|------|-----------------|---------|
| `oc` (OpenShift CLI) | `brew install openshift-cli`, or `scripts/install-tools.sh` on a connected host | almost every apply / verify / collect script |
| `jq` | `brew install jq` | trustee / secret / verify scripts |
| `skopeo` | `brew install skopeo` | build & verify rung images |
| `cosign` | `brew install cosign` | rung-signed signature verify |
| `python3` | preinstalled, or `brew install python` | `repair-sno-baseline.sh`, rung-encrypted key-wrap verify |
| `podman` | `brew install podman` (+ `podman machine start`) | building rung images locally |

Built into macOS and used directly (nothing to install): `shasum` (SHA-256), `base64`,
`awk`, `sed`, `find`, `bash`.

Optional: `kustomize` (`brew install kustomize`) if you want to run `scripts/lint.sh`
locally; otherwise it falls back to `oc kustomize`.

## Which scripts run where

Every script's header comment states its execution context. In short:

### On your operator workstation (macOS or Linux)

These drive the cluster via `oc` / `skopeo` / `cosign` and are the **bash-3.2 + BSD-portable
set**:

`apply-rung-kbs.sh`, `apply-rung-signed.sh`, `apply-rung-encrypted.sh`, `apply-rung-image.sh`,
`apply-sno.sh`, `apply-trustee.sh`, `build-rung-images.sh`, `collect-vcek.sh`,
`encode-initdata.sh`, `gen-rvps-veritas.sh`, `negative-test.sh`,
`render-measurement-policy.sh`, `repair-sno-baseline.sh`, `seed-trustee-secrets.sh`,
`uninstall-coco.sh`, `validate-sno-baseline.sh`, `verify-rung-signed-signature.sh`,
`verify-rung-encrypted-key-wrap.sh`, `verify-snp-host.sh`.

> `seed-trustee-secrets.sh` and `gen-rvps-veritas.sh` read bastion-local inputs (the VCEK
> bundle, mirror password); run them wherever those files live (often the bastion), but they
> are portable either way.

### On the bastion (Rocky Linux jump host)

Wired to bastion paths (`/opt/mirror`, `/opt/install`), `sudo`, and mirror / PXE plumbing.
They assume GNU coreutils and are **not** meant to run on a Mac:

`bastion-mirror-setup.sh`, `bastion-render-configs.sh`, `bastion-mirror-push.sh`,
`mirror.sh`, `serve-boot-artifacts.sh`, `install-tools.sh` (fetches CLI tooling — run on a
connected host).

### On the SNP host / cluster node (RHCOS or the bare host — GNU/Linux)

`host-snp-check.sh` (raw pre-OpenShift host), plus the **node-side code embedded inside
`oc debug … chroot /host` and cloud-init heredocs** in `repair-sno-baseline.sh` and
`gen-rvps-veritas.sh`. That code runs on RHCOS (GNU coreutils) and deliberately keeps its GNU
flags (`base64 -w0`, `stat -c`) — it never executes in the operator's local shell.

## How portability works (for contributors)

- **`scripts/lib/compat.sh`** is the portability shim. It provides `sha256_file`,
  `sha256_stdin`, `have_sha256`, `b64_oneline`, and `b64_decode`, choosing GNU vs BSD tools at
  runtime (`sha256sum` ↔ `shasum -a 256`, `base64 -d` ↔ `base64 -D`).
- Any script that hashes or base64-encodes **in the operator's local shell** sources it:

  ```bash
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=scripts/lib/compat.sh
  source "${REPO_ROOT}/scripts/lib/compat.sh"
  ```

- Use bash-3.2-safe constructs: replace `mapfile -t arr < <(cmd)` with a
  `while IFS= read -r line; do arr+=("$line"); done < <(cmd)` loop.
- **Node-side heredoc code stays GNU.** Code executed on the node via `oc debug` / `chroot`
  or cloud-init runs on RHCOS = GNU coreutils; do **not** route it through the shim. Annotate
  such lines so the intent is clear (see the examples in `repair-sno-baseline.sh`).
- **CI enforces all of the above.** `.github/workflows/scripts-ci.yml` runs `bash -n` (under
  macOS's system bash 3.2), `shellcheck`, and `scripts/lint.sh` on an **ubuntu + macos**
  matrix, so a GNU-only regression in a local-shell path fails the build.
