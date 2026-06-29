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
CONTAINER_VOLUME_SUFFIX="${CONTAINER_VOLUME_SUFFIX:-}"
COSIGN_KEY="${COSIGN_KEY:-${ARTIFACT_DIR}/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-${ARTIFACT_DIR}/cosign.pub}"
COSIGN_SIGN_ARGS="${COSIGN_SIGN_ARGS:-}"
COSIGN_VERIFY_ARGS="${COSIGN_VERIFY_ARGS:-}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
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

require_rung_b_key_size() {
	local size
	size="$(file_size_bytes "$RUNG_B_KEY_FILE")"
	[[ "$size" == "32" ]] || die "rung-b image key must be exactly 32 bytes: $RUNG_B_KEY_FILE (${size} bytes)"
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

detect_runtime() {
	if [[ -n "$CONTAINER_RUNTIME" ]]; then
		command -v "$CONTAINER_RUNTIME" >/dev/null || die "$CONTAINER_RUNTIME is not on PATH"
	else
		if command -v podman >/dev/null; then
			CONTAINER_RUNTIME=podman
		elif command -v docker >/dev/null; then
			CONTAINER_RUNTIME=docker
		else
			die "podman or docker is required to run the CoCo keyprovider image"
		fi
	fi

	if [[ -z "$CONTAINER_VOLUME_SUFFIX" && "$CONTAINER_RUNTIME" == "podman" ]]; then
		CONTAINER_VOLUME_SUFFIX=":Z"
	fi
}

keyprovider_image_exists() {
	case "$CONTAINER_RUNTIME" in
		podman) podman image exists "$COCO_KEYPROVIDER_IMAGE" ;;
		docker) docker image inspect "$COCO_KEYPROVIDER_IMAGE" >/dev/null 2>&1 ;;
		*) "$CONTAINER_RUNTIME" image inspect "$COCO_KEYPROVIDER_IMAGE" >/dev/null 2>&1 ;;
	esac
}

require_keyprovider_image() {
	if keyprovider_image_exists; then
		return
	fi
	die "missing CoCo keyprovider image '$COCO_KEYPROVIDER_IMAGE'. Build it from guest-components with: ${CONTAINER_RUNTIME} build -t ${COCO_KEYPROVIDER_IMAGE} -f ./attestation-agent/docker/Dockerfile.keyprovider ."
}

default_cosign_sign_args() {
	local help args
	args="--yes --tlog-upload=false"
	help="$(cosign sign --help 2>&1 || true)"
	if grep -Fq -- "--new-bundle-format" <<<"$help"; then
		args+=" --new-bundle-format=false"
	fi
	if grep -Fq -- "--use-signing-config" <<<"$help"; then
		args+=" --use-signing-config=false"
	fi
	printf '%s\n' "$args"
}

configure_cosign_args() {
	if [[ -z "$COSIGN_SIGN_ARGS" ]]; then
		COSIGN_SIGN_ARGS="$(default_cosign_sign_args)"
	fi
	if [[ -z "$COSIGN_VERIFY_ARGS" ]]; then
		COSIGN_VERIFY_ARGS="--insecure-ignore-tlog=true"
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
	local c_digest c_digest_ref
	[[ -n "${COSIGN_PASSWORD:-}" ]] || die "set COSIGN_PASSWORD to sign the rung-c image"
	echo "Pushing unsigned rung-c negative-control image: $RUNG_C_UNSIGNED_IMAGE"
	skopeo copy "$SOURCE_IMAGE_REF" "docker://${RUNG_C_UNSIGNED_IMAGE}"
	echo "Pushing rung-c image to sign: $RUNG_C_IMAGE"
	skopeo copy "$SOURCE_IMAGE_REF" "docker://${RUNG_C_IMAGE}"
	c_digest="$(skopeo inspect "docker://${RUNG_C_IMAGE}" | jq -r '.Digest')"
	c_digest_ref="$(image_digest_ref "$RUNG_C_IMAGE" "$c_digest")"
	echo "Signing rung-c image digest with $COSIGN_KEY: $c_digest_ref"
	# shellcheck disable=SC2086
	COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign sign $COSIGN_SIGN_ARGS --key "$COSIGN_KEY" "$c_digest_ref"
	# shellcheck disable=SC2086
	cosign verify $COSIGN_VERIFY_ARGS --key "$COSIGN_PUB" "$c_digest_ref" >/dev/null
}

write_manifest() {
	local b_digest c_digest c_unsigned_digest b_digest_ref c_digest_ref c_unsigned_digest_ref manifest
	b_digest="$(skopeo inspect "docker://${RUNG_B_IMAGE}" | jq -r '.Digest')"
	c_digest="$(skopeo inspect "docker://${RUNG_C_IMAGE}" | jq -r '.Digest')"
	c_unsigned_digest="$(skopeo inspect "docker://${RUNG_C_UNSIGNED_IMAGE}" | jq -r '.Digest')"
	b_digest_ref="$(image_digest_ref "$RUNG_B_IMAGE" "$b_digest")"
	c_digest_ref="$(image_digest_ref "$RUNG_C_IMAGE" "$c_digest")"
	c_unsigned_digest_ref="$(image_digest_ref "$RUNG_C_UNSIGNED_IMAGE" "$c_unsigned_digest")"
	manifest="$ARTIFACT_DIR/rung-bc-images.json"
	jq -n \
		--arg source "$SOURCE_IMAGE_REF" \
		--arg rung_b_image "$RUNG_B_IMAGE" \
		--arg rung_b_digest "$b_digest" \
		--arg rung_b_digest_ref "$b_digest_ref" \
		--arg rung_b_key_id "$RUNG_B_KEY_ID" \
		--arg rung_b_key_file "$RUNG_B_KEY_FILE" \
		--arg rung_c_image "$RUNG_C_IMAGE" \
		--arg rung_c_digest "$c_digest" \
		--arg rung_c_digest_ref "$c_digest_ref" \
		--arg rung_c_unsigned_image "$RUNG_C_UNSIGNED_IMAGE" \
		--arg rung_c_unsigned_digest "$c_unsigned_digest" \
		--arg rung_c_unsigned_digest_ref "$c_unsigned_digest_ref" \
		--arg cosign_pub "$COSIGN_PUB" \
		'{
			source_image: $source,
			rung_b: {
				image: $rung_b_image,
				digest: $rung_b_digest,
				digest_ref: $rung_b_digest_ref,
				key_id: $rung_b_key_id,
				key_file: $rung_b_key_file
			},
			rung_c: {
				image: $rung_c_image,
				digest: $rung_c_digest,
				digest_ref: $rung_c_digest_ref,
				unsigned_image: $rung_c_unsigned_image,
				unsigned_digest: $rung_c_unsigned_digest,
				unsigned_digest_ref: $rung_c_unsigned_digest_ref,
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

if [[ "${1:-}" == "digest-ref" ]]; then
	[[ "$#" -eq 3 ]] || die "usage: $0 digest-ref <image-ref> <sha256:digest>"
	image_digest_ref "$2" "$3"
	exit 0
fi

if [[ "${1:-}" == "default-cosign-sign-args" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 default-cosign-sign-args"
	default_cosign_sign_args
	exit 0
fi

if [[ "${1:-}" == "sign-rung-c-only" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 sign-rung-c-only"
	need skopeo
	need jq
	need cosign
	configure_cosign_args
	sign_rung_c
	exit 0
fi

need skopeo
need jq
need openssl
need base64
need cosign
configure_cosign_args
detect_runtime
require_keyprovider_image

mkdir -p "$ARTIFACT_DIR"
generate_rung_b_key
require_rung_b_key_size
ensure_cosign_keys
encrypt_rung_b
sign_rung_c
write_manifest
