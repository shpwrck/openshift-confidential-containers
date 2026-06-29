#!/usr/bin/env bash
# Build/push the image artifacts needed for rung-b (encrypted) and rung-c (signed).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.rig.local:8443}"
SOURCE_IMAGE="${SOURCE_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal@sha256:4ba37413a8284073eb28f1987fdf8f7b9cc3d301807cdd79e10ab5b98bd57a63}"
SOURCE_IMAGE_REF="${SOURCE_IMAGE_REF:-docker://${SOURCE_IMAGE}}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
RUNG_B_IMAGE="${RUNG_B_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b:encrypted}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-${MIRROR_REGISTRY}/coco/rung-c:signed}"
RUNG_C_UNSIGNED_IMAGE="${RUNG_C_UNSIGNED_IMAGE:-${MIRROR_REGISTRY}/coco/rung-c:unsigned}"
RUNG_B_KEY_PATH="${RUNG_B_KEY_PATH:-/default/image-key/rung-b}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-kbs://${RUNG_B_KEY_PATH}}"
RUNG_B_KEY_FILE="${RUNG_B_KEY_FILE:-${ARTIFACT_DIR}/rung-b-image.key}"
COCO_KEYPROVIDER_IMAGE="${COCO_KEYPROVIDER_IMAGE:-coco-keyprovider}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
CONTAINER_VOLUME_SUFFIX="${CONTAINER_VOLUME_SUFFIX:-:Z}"
COSIGN_KEY="${COSIGN_KEY:-${ARTIFACT_DIR}/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-${ARTIFACT_DIR}/cosign.pub}"
COSIGN_SIGN_ARGS="${COSIGN_SIGN_ARGS:---yes --tlog-upload=false}"
COSIGN_VERIFY_ARGS="${COSIGN_VERIFY_ARGS:---insecure-ignore-tlog=true}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

detect_runtime() {
	if [[ -n "$CONTAINER_RUNTIME" ]]; then
		command -v "$CONTAINER_RUNTIME" >/dev/null || die "$CONTAINER_RUNTIME is not on PATH"
		return
	fi
	if command -v podman >/dev/null; then
		CONTAINER_RUNTIME=podman
	elif command -v docker >/dev/null; then
		CONTAINER_RUNTIME=docker
	else
		die "podman or docker is required to run the CoCo keyprovider image"
	fi
}

generate_rung_b_key() {
	if [[ -s "$RUNG_B_KEY_FILE" ]]; then
		return
	fi
	echo "Generating 32-byte rung-b image key: $RUNG_B_KEY_FILE"
	openssl rand 32 > "$RUNG_B_KEY_FILE"
	chmod 0600 "$RUNG_B_KEY_FILE"
}

ensure_cosign_keys() {
	if [[ -s "$COSIGN_KEY" && -s "$COSIGN_PUB" ]]; then
		return
	fi
	[[ -n "${COSIGN_PASSWORD:-}" ]] || die "set COSIGN_PASSWORD to generate/sign the rung-c key pair"
	echo "Generating cosign key pair under $ARTIFACT_DIR"
	(
		cd "$ARTIFACT_DIR"
		COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign generate-key-pair >/dev/null
	)
	[[ -s "$COSIGN_KEY" && -s "$COSIGN_PUB" ]] || die "cosign key generation did not create $COSIGN_KEY and $COSIGN_PUB"
	chmod 0600 "$COSIGN_KEY"
}

encrypt_rung_b() {
	local key_b64 oci_dir
	key_b64="$(base64 < "$RUNG_B_KEY_FILE" | tr -d '\n')"
	oci_dir="$ARTIFACT_DIR/oci"
	rm -rf "$oci_dir"
	mkdir -p "$oci_dir/input" "$oci_dir/output"

	echo "Copying source image to OCI dir: $SOURCE_IMAGE_REF"
	skopeo copy "$SOURCE_IMAGE_REF" "dir:${oci_dir}/input"

	echo "Encrypting rung-b image with KID $RUNG_B_KEY_ID"
	"$CONTAINER_RUNTIME" run --rm \
		-v "${oci_dir}:/oci${CONTAINER_VOLUME_SUFFIX}" \
		"$COCO_KEYPROVIDER_IMAGE" \
		/encrypt.sh -k "$key_b64" -i "$RUNG_B_KEY_ID" -s dir:/oci/input -d dir:/oci/output

	skopeo inspect "dir:${oci_dir}/output" | jq -e --arg kid "$RUNG_B_KEY_ID" '
		[
			.LayersData[]?.Annotations["org.opencontainers.image.enc.keys.provider.attestation-agent"]?
			| select(. != null)
			| @base64d
			| fromjson
			| select(.kid == $kid)
		] | length > 0
	' >/dev/null

	echo "Pushing encrypted rung-b image: $RUNG_B_IMAGE"
	skopeo copy "dir:${oci_dir}/output" "docker://${RUNG_B_IMAGE}"
}

sign_rung_c() {
	[[ -n "${COSIGN_PASSWORD:-}" ]] || die "set COSIGN_PASSWORD to sign the rung-c image"
	echo "Pushing unsigned rung-c negative-control image: $RUNG_C_UNSIGNED_IMAGE"
	skopeo copy "$SOURCE_IMAGE_REF" "docker://${RUNG_C_UNSIGNED_IMAGE}"
	echo "Pushing rung-c image to sign: $RUNG_C_IMAGE"
	skopeo copy "$SOURCE_IMAGE_REF" "docker://${RUNG_C_IMAGE}"
	echo "Signing rung-c image with $COSIGN_KEY"
	# shellcheck disable=SC2086
	COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign sign $COSIGN_SIGN_ARGS --key "$COSIGN_KEY" "$RUNG_C_IMAGE"
	# shellcheck disable=SC2086
	cosign verify $COSIGN_VERIFY_ARGS --key "$COSIGN_PUB" "$RUNG_C_IMAGE" >/dev/null
}

write_manifest() {
	local b_digest c_digest c_unsigned_digest manifest
	b_digest="$(skopeo inspect "docker://${RUNG_B_IMAGE}" | jq -r '.Digest')"
	c_digest="$(skopeo inspect "docker://${RUNG_C_IMAGE}" | jq -r '.Digest')"
	c_unsigned_digest="$(skopeo inspect "docker://${RUNG_C_UNSIGNED_IMAGE}" | jq -r '.Digest')"
	manifest="$ARTIFACT_DIR/rung-bc-images.json"
	jq -n \
		--arg source "$SOURCE_IMAGE_REF" \
		--arg rung_b_image "$RUNG_B_IMAGE" \
		--arg rung_b_digest "$b_digest" \
		--arg rung_b_key_id "$RUNG_B_KEY_ID" \
		--arg rung_b_key_file "$RUNG_B_KEY_FILE" \
		--arg rung_c_image "$RUNG_C_IMAGE" \
		--arg rung_c_digest "$c_digest" \
		--arg rung_c_unsigned_image "$RUNG_C_UNSIGNED_IMAGE" \
		--arg rung_c_unsigned_digest "$c_unsigned_digest" \
		--arg cosign_pub "$COSIGN_PUB" \
		'{
			source_image: $source,
			rung_b: {
				image: $rung_b_image,
				digest: $rung_b_digest,
				digest_ref: ($rung_b_image | sub(":[^/:@]+$"; "@" + $rung_b_digest)),
				key_id: $rung_b_key_id,
				key_file: $rung_b_key_file
			},
			rung_c: {
				image: $rung_c_image,
				digest: $rung_c_digest,
				digest_ref: ($rung_c_image | sub(":[^/:@]+$"; "@" + $rung_c_digest)),
				unsigned_image: $rung_c_unsigned_image,
				unsigned_digest: $rung_c_unsigned_digest,
				unsigned_digest_ref: ($rung_c_unsigned_image | sub(":[^/:@]+$"; "@" + $rung_c_unsigned_digest)),
				cosign_pub: $cosign_pub
			}
		}' > "$manifest"
	echo "Wrote $manifest"
	jq -r '
		"RUNG_B_IMAGE=" + .rung_b.digest_ref,
		"RUNG_B_KEY_FILE=" + .rung_b.key_file,
		"RUNG_C_IMAGE=" + .rung_c.digest_ref,
		"RUNG_C_UNSIGNED_IMAGE=" + .rung_c.unsigned_digest_ref,
		"RUNG_C_COSIGN_PUB=" + .rung_c.cosign_pub
	' "$manifest"
}

need skopeo
need jq
need openssl
need base64
need cosign
detect_runtime

mkdir -p "$ARTIFACT_DIR"
generate_rung_b_key
ensure_cosign_keys
encrypt_rung_b
sign_rung_c
write_manifest
