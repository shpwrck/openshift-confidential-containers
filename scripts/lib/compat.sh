# shellcheck shell=bash
# scripts/lib/compat.sh — portability shim for OPERATOR-LOCAL shell code.
#
# The operator runbooks are driven from a stock macOS workstation as well as Linux.
# macOS ships BSD userland + bash 3.2, so GNU-coreutils flags (`sha256sum`,
# `base64 -w0`, `readlink -f`, `stat -c`) and bash-4 builtins (`mapfile`) are not
# available. Source this shim from any script that runs those in the operator's
# local shell:
#
#     REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#     source "${REPO_ROOT}/scripts/lib/compat.sh"
#
# SCOPE: these helpers are for LOCAL-shell paths ONLY. Code that runs on the
# cluster node — inside `oc debug node … chroot /host` or a cloud-init / ssh
# heredoc — executes on RHCOS/RHEL (GNU coreutils) and MUST keep its GNU flags.
# Do not route node-side heredoc code through this shim.
#
# The base64 helper mirrors the pre-existing portable pattern in
# scripts/gen-rvps-veritas.sh (b64/b64d), generalized here for reuse.

# --- sha256 -----------------------------------------------------------------
# GNU coreutils:  sha256sum
# macOS/BSD:      shasum -a 256   (always present on macOS — part of the base Perl)
# fallback:       openssl dgst -sha256 -r  ("-r" = coreutils-style "<hash>  <file>")
# All three print the hex digest as whitespace field 1, so `awk '{print $1}'`
# normalizes the output identically across platforms.
if command -v sha256sum >/dev/null 2>&1; then
	COMPAT_SHA256=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
	COMPAT_SHA256=(shasum -a 256)
elif command -v openssl >/dev/null 2>&1; then
	COMPAT_SHA256=(openssl dgst -sha256 -r)
else
	COMPAT_SHA256=()
fi

# sha256_file <path> — hex digest of a file.
sha256_file() { _require_sha256 || return; "${COMPAT_SHA256[@]}" "$1" | awk '{print $1}'; }

# sha256_stdin — hex digest of stdin (e.g. `printf %s "$x" | sha256_stdin`).
sha256_stdin() { _require_sha256 || return; "${COMPAT_SHA256[@]}" | awk '{print $1}'; }

# have_sha256 — silent predicate for a script's dependency preflight, used in
# place of a `command -v sha256sum` check. True when a sha256 tool is on PATH, so
# callers supply their own message: `have_sha256 || die "..."`.
have_sha256() { [[ ${#COMPAT_SHA256[@]} -gt 0 ]]; }

# _require_sha256 — fail loudly (rc 127, as a missing command would) instead of silently
# emitting an empty digest when no sha256 tool exists. Guards sha256_file/sha256_stdin so an
# unguarded caller (e.g. vcek_secret_name) can never derive a truncated/wrong secret name from
# empty output — with `set -o pipefail` the empty pipe would otherwise succeed.
_require_sha256() { have_sha256 || { echo "ERROR: no sha256 tool found (need sha256sum, shasum, or openssl)" >&2; return 127; }; }

# --- base64 -----------------------------------------------------------------
# b64_oneline [file] — base64 with no line wrapping (replaces GNU `base64 -w0`).
# With a file argument it encodes that file; otherwise it encodes stdin. Plain
# `base64` (no flags) encodes on both GNU and BSD; `tr -d '\n'` strips the BSD
# line wrapping that GNU's `-w0` would suppress.
# shellcheck disable=SC2120  # intentionally callable with no args (stdin mode)
b64_oneline() {
	if [[ $# -gt 0 ]]; then
		base64 <"$1" | tr -d '\n'
	else
		base64 | tr -d '\n'
	fi
}

# Decode flag differs: GNU coreutils uses `-d`, BSD/macOS uses `-D`. Probe once.
if printf '' | base64 -d >/dev/null 2>&1; then
	COMPAT_B64D=(base64 -d)
else
	COMPAT_B64D=(base64 -D)
fi

# b64_decode — decode base64 from stdin (replaces GNU `base64 -d`), e.g.
# `printf %s "$b64" | b64_decode >out` or `some_cmd | b64_decode >out`.
b64_decode() { "${COMPAT_B64D[@]}"; }
