#!/usr/bin/env bash
# Verify that the configured rung-b public key accepts only the signed image ref.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.rig.local:8443}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
RUNG_B_IMAGE="${RUNG_B_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b:signed}"
RUNG_B_UNSIGNED_IMAGE="${RUNG_B_UNSIGNED_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b-unsigned:unsigned}"
RUNG_B_IMAGE_REF="${RUNG_B_IMAGE_REF:-}"
RUNG_B_UNSIGNED_IMAGE_REF="${RUNG_B_UNSIGNED_IMAGE_REF:-}"
RUNG_B_COSIGN_PUB="${RUNG_B_COSIGN_PUB:-${ARTIFACT_DIR}/cosign.pub}"
RUNG_BC_IMAGES_MANIFEST="${RUNG_BC_IMAGES_MANIFEST:-${ARTIFACT_DIR}/rung-bc-images.json}"
REQUIRE_RUNG_BC_IMAGES_MANIFEST="${REQUIRE_RUNG_BC_IMAGES_MANIFEST:-0}"
COSIGN_VERIFY_ARGS="${COSIGN_VERIFY_ARGS:---insecure-ignore-tlog=true}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

pass() {
	printf 'PASS: %s\n' "$*"
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

usage() {
	cat <<EOF
Usage: verify-rung-b-signature.sh

Inspect the rung-b signed image and unsigned negative-control image, verify the
signed digest with RUNG_B_COSIGN_PUB, and require the unsigned control not to
verify with that same key.

Key env:
  RUNG_B_IMAGE                    signed image ref without transport
  RUNG_B_UNSIGNED_IMAGE           unsigned negative-control image ref without transport
  RUNG_B_IMAGE_REF                full skopeo ref override for the signed image
  RUNG_B_UNSIGNED_IMAGE_REF       full skopeo ref override for the unsigned control
  RUNG_B_COSIGN_PUB               cosign public key file
  COSIGN_VERIFY_ARGS              extra cosign verify flags
  RUNG_BC_IMAGES_MANIFEST         optional rung-bc-images.json consistency check
  REQUIRE_RUNG_BC_IMAGES_MANIFEST set 1 to fail when the manifest is missing
EOF
}

file_sha256() {
	local path="$1"
	if [[ -r "$path" ]]; then
		sha256sum "$path" | awk '{print $1}'
	elif command -v sudo >/dev/null && sudo -n test -r "$path" 2>/dev/null; then
		sudo -n sha256sum "$path" | awk '{print $1}'
	else
		die "cannot read $path"
	fi
}

image_transport_ref() {
	local image="$1"
	case "$image" in
		docker://*|dir:*|oci:*|containers-storage:*|docker-archive:*|oci-archive:*) printf '%s\n' "$image" ;;
		*) printf 'docker://%s\n' "$image" ;;
	esac
}

image_digest_ref() {
	local image="$1" digest="$2" base last_segment
	if [[ "$image" == *@* ]]; then
		base="${image%@*}"
	else
		last_segment="${image##*/}"
		if [[ "$last_segment" == *:* ]]; then
			base="${image%:*}"
		else
			base="$image"
		fi
	fi
	printf '%s@%s\n' "$base" "$digest"
}

inspect_digest_ref() {
	local image="$1" image_ref="$2" label="$3" inspect_json digest
	inspect_json="$(mktemp)"
	skopeo inspect "${image_ref:-$(image_transport_ref "$image")}" > "$inspect_json"
	digest="$(jq -r '.Digest // ""' "$inspect_json")"
	rm -f "$inspect_json"
	[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$label image digest missing from skopeo inspect"
	image_digest_ref "$image" "$digest"
}

verify_manifest_consistency() {
	local manifest="$1" signed_digest_ref="$2" unsigned_digest_ref="$3" pub_sha="$4"
	if [[ ! -s "$manifest" ]]; then
		if [[ "$REQUIRE_RUNG_BC_IMAGES_MANIFEST" == "1" ]]; then
			fail "rung-b/c image manifest missing: $manifest"
		fi
		pass "rung-b/c image manifest not present; skipped manifest consistency check"
		return
	fi
	jq -e \
		--arg signed_digest_ref "$signed_digest_ref" \
		--arg unsigned_digest_ref "$unsigned_digest_ref" \
		--arg pub_sha "$pub_sha" '
		.rung_b.digest_ref == $signed_digest_ref and
		.rung_b.unsigned_digest_ref == $unsigned_digest_ref and
		.rung_b.cosign_pub_sha256 == $pub_sha
	' "$manifest" >/dev/null || fail "rung-b/c manifest does not match rung-b signed digest, unsigned digest, or public key fingerprint: $manifest"
	pass "rung-b/c manifest matches rung-b signed digest, unsigned digest, and public key fingerprint"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

need skopeo
need jq
need sha256sum
need cosign

[[ -s "$RUNG_B_COSIGN_PUB" ]] || die "missing rung-b cosign public key: $RUNG_B_COSIGN_PUB"
pub_sha="$(file_sha256 "$RUNG_B_COSIGN_PUB")"
pass "rung-b cosign public key is readable"

signed_digest_ref="$(inspect_digest_ref "$RUNG_B_IMAGE" "$RUNG_B_IMAGE_REF" "rung-b signed")"
pass "rung-b signed image digest resolved to $signed_digest_ref"
unsigned_digest_ref="$(inspect_digest_ref "$RUNG_B_UNSIGNED_IMAGE" "$RUNG_B_UNSIGNED_IMAGE_REF" "rung-b unsigned")"
pass "rung-b unsigned image digest resolved to $unsigned_digest_ref"
[[ "$signed_digest_ref" != "$unsigned_digest_ref" ]] || fail "rung-b signed and unsigned image refs resolve to the same digest ref: $signed_digest_ref"

verify_manifest_consistency "$RUNG_BC_IMAGES_MANIFEST" "$signed_digest_ref" "$unsigned_digest_ref" "$pub_sha"

# shellcheck disable=SC2086
cosign verify $COSIGN_VERIFY_ARGS --key "$RUNG_B_COSIGN_PUB" "$signed_digest_ref" >/dev/null
pass "configured public key verifies rung-b signed image"

# shellcheck disable=SC2086
if cosign verify $COSIGN_VERIFY_ARGS --key "$RUNG_B_COSIGN_PUB" "$unsigned_digest_ref" >/dev/null 2>&1; then
	fail "rung-b unsigned negative-control image unexpectedly verifies with the configured public key: $unsigned_digest_ref"
fi
pass "rung-b unsigned negative-control image does not verify with the configured public key"
echo "Rung-b signature verification OK."
