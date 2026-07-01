#!/usr/bin/env bash
# Verify that the configured rung-c KEK unwraps the encrypted image layer key.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR_REGISTRY="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-${MIRROR_REGISTRY}/coco/rung-c:encrypted}"
RUNG_C_IMAGE_REF="${RUNG_C_IMAGE_REF:-}"
RUNG_C_KEY_ID="${RUNG_C_KEY_ID:-kbs:///default/image-key/rung-c}"
RUNG_C_KEY_FILE="${RUNG_C_KEY_FILE:-${ARTIFACT_DIR}/rung-c-image.key}"
RUNG_BC_IMAGES_MANIFEST="${RUNG_BC_IMAGES_MANIFEST:-${ARTIFACT_DIR}/rung-bc-images.json}"
REQUIRE_RUNG_BC_IMAGES_MANIFEST="${REQUIRE_RUNG_BC_IMAGES_MANIFEST:-0}"
ANNOTATION_KEY="org.opencontainers.image.enc.keys.provider.attestation-agent"

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
Usage: verify-rung-c-key-wrap.sh

Inspect the rung-c encrypted image metadata and verify that RUNG_C_KEY_FILE decrypts
the A256GCM-wrapped layer key recorded in the attestation-agent annotation. The
script does not print key material or the unwrapped layer key.

Key env:
  RUNG_C_IMAGE                    image ref without transport (default: ${MIRROR_REGISTRY}/coco/rung-c:encrypted)
  RUNG_C_IMAGE_REF                full skopeo ref override, e.g. docker://... or dir:/...
  RUNG_C_KEY_ID                   expected kbs:/// key ID
  RUNG_C_KEY_FILE                 32-byte KEK file
  RUNG_BC_IMAGES_MANIFEST         optional rung-bc-images.json consistency check
  REQUIRE_RUNG_BC_IMAGES_MANIFEST set 1 to fail when the manifest is missing
EOF
}

file_size_bytes() {
	local path="$1"
	if [[ -r "$path" ]]; then
		wc -c < "$path" | tr -d '[:space:]'
	elif command -v sudo >/dev/null && sudo -n test -r "$path" 2>/dev/null; then
		sudo -n wc -c "$path" | awk '{print $1}'
	else
		die "cannot read $path"
	fi
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

verify_manifest_consistency() {
	local manifest="$1" digest_ref="$2" key_sha="$3"
	if [[ ! -s "$manifest" ]]; then
		if [[ "$REQUIRE_RUNG_BC_IMAGES_MANIFEST" == "1" ]]; then
			fail "rung-b/c image manifest missing: $manifest"
		fi
		pass "rung-b/c image manifest not present; skipped manifest consistency check"
		return
	fi
	jq -e \
		--arg digest_ref "$digest_ref" \
		--arg key_id "$RUNG_C_KEY_ID" \
		--arg key_sha "$key_sha" '
		.rung_c.digest_ref == $digest_ref and
		.rung_c.key_id == $key_id and
		.rung_c.key_sha256 == $key_sha
	' "$manifest" >/dev/null || fail "rung-b/c manifest does not match image digest, key ID, or key fingerprint: $manifest"
	pass "rung-b/c manifest matches image digest, key ID, and key fingerprint"
}

decrypt_annotation() {
	local annotation_json="$1" key_file="$2"
	python3 - "$annotation_json" "$key_file" <<'PY'
import base64
import ctypes
import ctypes.util
import json
import sys

annotation_path, key_path = sys.argv[1:3]
annotation = json.load(open(annotation_path, encoding="utf-8"))
if annotation.get("wrap_type") != "A256GCM":
    print(f"unsupported wrap_type: {annotation.get('wrap_type')}", file=sys.stderr)
    sys.exit(3)

key = open(key_path, "rb").read()
iv = base64.b64decode(annotation["iv"])
wrapped = base64.b64decode(annotation["wrapped_data"])
if len(key) != 32:
    print(f"key must be 32 bytes, got {len(key)}", file=sys.stderr)
    sys.exit(3)
if len(iv) == 0 or len(wrapped) <= 16:
    print("annotation has invalid iv or wrapped_data", file=sys.stderr)
    sys.exit(3)

ciphertext, tag = wrapped[:-16], wrapped[-16:]
libname = ctypes.util.find_library("crypto") or "libcrypto.so"
lib = ctypes.CDLL(libname)

EVP_CIPHER_CTX_new = lib.EVP_CIPHER_CTX_new
EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
EVP_CIPHER_CTX_free = lib.EVP_CIPHER_CTX_free
EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
EVP_aes_256_gcm = lib.EVP_aes_256_gcm
EVP_aes_256_gcm.restype = ctypes.c_void_p
EVP_DecryptInit_ex = lib.EVP_DecryptInit_ex
EVP_DecryptInit_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
EVP_DecryptInit_ex.restype = ctypes.c_int
EVP_CIPHER_CTX_ctrl = lib.EVP_CIPHER_CTX_ctrl
EVP_CIPHER_CTX_ctrl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
EVP_CIPHER_CTX_ctrl.restype = ctypes.c_int
EVP_DecryptUpdate = lib.EVP_DecryptUpdate
EVP_DecryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p, ctypes.c_int]
EVP_DecryptUpdate.restype = ctypes.c_int
EVP_DecryptFinal_ex = lib.EVP_DecryptFinal_ex
EVP_DecryptFinal_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
EVP_DecryptFinal_ex.restype = ctypes.c_int

EVP_CTRL_GCM_SET_IVLEN = 0x9
EVP_CTRL_GCM_SET_TAG = 0x11
ctx = EVP_CIPHER_CTX_new()
if not ctx:
    print("failed to create OpenSSL cipher context", file=sys.stderr)
    sys.exit(3)

try:
    def require(ok, label):
        if ok != 1:
            print(f"OpenSSL AES-GCM step failed: {label}", file=sys.stderr)
            sys.exit(3)

    require(EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), None, None, None), "init")
    require(EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, len(iv), None), "iv length")
    key_buf = ctypes.create_string_buffer(key)
    iv_buf = ctypes.create_string_buffer(iv)
    require(EVP_DecryptInit_ex(ctx, None, None, key_buf, iv_buf), "key/iv")
    out = ctypes.create_string_buffer(len(ciphertext) + 16)
    out_len = ctypes.c_int(0)
    ct_buf = ctypes.create_string_buffer(ciphertext)
    require(EVP_DecryptUpdate(ctx, out, ctypes.byref(out_len), ct_buf, len(ciphertext)), "decrypt update")
    tag_buf = ctypes.create_string_buffer(tag)
    require(EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, len(tag), tag_buf), "auth tag")
    final_len = ctypes.c_int(0)
    if EVP_DecryptFinal_ex(ctx, ctypes.byref(out, out_len.value), ctypes.byref(final_len)) != 1:
        print("configured key did not authenticate/decrypt wrapped_data", file=sys.stderr)
        sys.exit(1)
    plaintext_len = out_len.value + final_len.value
    if plaintext_len == 0:
        print("wrapped key decrypted to an empty plaintext", file=sys.stderr)
        sys.exit(1)
    print(f"plaintext_len={plaintext_len}")
finally:
    EVP_CIPHER_CTX_free(ctx)
PY
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

need skopeo
need jq
need base64
need sha256sum
need python3

[[ -s "$RUNG_C_KEY_FILE" ]] || die "missing rung-c key file: $RUNG_C_KEY_FILE"
key_size="$(file_size_bytes "$RUNG_C_KEY_FILE")"
[[ "$key_size" == "32" ]] || fail "rung-c key must be exactly 32 bytes: $RUNG_C_KEY_FILE (${key_size} bytes)"
pass "rung-c key file is 32 bytes"

image_ref="${RUNG_C_IMAGE_REF:-$(image_transport_ref "$RUNG_C_IMAGE")}"
inspect_json="$(mktemp)"
annotation_json="$(mktemp)"
trap 'rm -f "$inspect_json" "$annotation_json"' EXIT

skopeo inspect "$image_ref" > "$inspect_json"
digest="$(jq -r '.Digest // ""' "$inspect_json")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "rung-c image digest missing from skopeo inspect: $image_ref"
digest_ref="$(image_digest_ref "$RUNG_C_IMAGE" "$digest")"
pass "rung-c image digest resolved to $digest_ref"

key_sha="$(file_sha256 "$RUNG_C_KEY_FILE")"
verify_manifest_consistency "$RUNG_BC_IMAGES_MANIFEST" "$digest_ref" "$key_sha"

annotation_count=0
matching_count=0
decrypted_count=0
while IFS= read -r annotation_b64; do
	[[ -n "$annotation_b64" ]] || continue
	annotation_count=$((annotation_count + 1))
	if ! printf '%s' "$annotation_b64" | base64 -d > "$annotation_json"; then
		fail "encrypted layer annotation is not valid base64 JSON"
	fi
	kid="$(jq -r '.kid // ""' "$annotation_json")"
	if [[ "$kid" != "$RUNG_C_KEY_ID" ]]; then
		continue
	fi
	matching_count=$((matching_count + 1))
	wrap_type="$(jq -r '.wrap_type // ""' "$annotation_json")"
	[[ "$wrap_type" == "A256GCM" ]] || fail "unsupported rung-c encrypted layer wrap_type: ${wrap_type:-missing}"
	decrypt_output="$(decrypt_annotation "$annotation_json" "$RUNG_C_KEY_FILE" 2>&1)" || fail "$decrypt_output"
	decrypted_count=$((decrypted_count + 1))
done < <(jq -r --arg key "$ANNOTATION_KEY" '.LayersData[]?.Annotations[$key]? // empty' "$inspect_json")

(( annotation_count > 0 )) || fail "no attestation-agent encrypted layer annotations found in $image_ref"
pass "found $annotation_count encrypted layer annotation(s)"
(( matching_count > 0 )) || fail "no encrypted layer annotation matched RUNG_C_KEY_ID=$RUNG_C_KEY_ID"
pass "found $matching_count encrypted layer annotation(s) for RUNG_C_KEY_ID"
(( decrypted_count == matching_count )) || fail "only decrypted $decrypted_count of $matching_count matching annotation(s)"
pass "configured rung-c key unwraps $decrypted_count encrypted layer key annotation(s)"
echo "Rung-b key wrap verification OK."
