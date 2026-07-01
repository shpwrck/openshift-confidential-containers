#!/usr/bin/env bash
# Build/push the image artifacts needed for rung-c (encrypted) and rung-b (signed).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR_REGISTRY="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
# Default to the MIRROR copy: this repo targets an air-gapped bastion where the public
# registry.access.redhat.com is unreachable. The mirror preserves the manifest digest; override
# SOURCE_IMAGE for a connected build.
SOURCE_IMAGE="${SOURCE_IMAGE:-${MIRROR_REGISTRY}/ubi9/ubi-minimal@sha256:4ba37413a8284073eb28f1987fdf8f7b9cc3d301807cdd79e10ab5b98bd57a63}"
SOURCE_IMAGE_REF="${SOURCE_IMAGE_REF:-docker://${SOURCE_IMAGE}}"
SKOPEO_COPY_ARGS="${SKOPEO_COPY_ARGS:---remove-signatures}"
# TLS-verify escape for registry reads/inspects, independent of SKOPEO_COPY_ARGS — e.g. on a fresh
# box that lacks the mirror CA: SKOPEO_INSPECT_ARGS="--tls-verify=false".
SKOPEO_INSPECT_ARGS="${SKOPEO_INSPECT_ARGS:-}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-${MIRROR_REGISTRY}/coco/rung-c:encrypted}"
RUNG_B_IMAGE="${RUNG_B_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b:signed}"
RUNG_B_UNSIGNED_IMAGE="${RUNG_B_UNSIGNED_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b-unsigned:unsigned}"
RUNG_C_KEY_PATH="${RUNG_C_KEY_PATH:-/default/image-key/rung-c}"
RUNG_C_KEY_ID="${RUNG_C_KEY_ID:-kbs://${RUNG_C_KEY_PATH}}"
RUNG_C_KEY_FILE="${RUNG_C_KEY_FILE:-${ARTIFACT_DIR}/rung-c-image.key}"
COCO_KEYPROVIDER_IMAGE="${COCO_KEYPROVIDER_IMAGE:-coco-keyprovider}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
CONTAINER_VOLUME_SUFFIX="${CONTAINER_VOLUME_SUFFIX:-}"
COSIGN_KEY="${COSIGN_KEY:-${ARTIFACT_DIR}/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-${ARTIFACT_DIR}/cosign.pub}"
COSIGN_SIGN_ARGS="${COSIGN_SIGN_ARGS:-}"
COSIGN_VERIFY_ARGS="${COSIGN_VERIFY_ARGS:-}"
VERIFY_RUNG_ARTIFACTS_AFTER_BUILD="${VERIFY_RUNG_ARTIFACTS_AFTER_BUILD:-1}"
VERIFY_RUNG_C_KEY_WRAP_SCRIPT="${VERIFY_RUNG_C_KEY_WRAP_SCRIPT:-${REPO_ROOT}/scripts/verify-rung-c-key-wrap.sh}"
VERIFY_RUNG_B_SIGNATURE_SCRIPT="${VERIFY_RUNG_B_SIGNATURE_SCRIPT:-${REPO_ROOT}/scripts/verify-rung-b-signature.sh}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

# skopeo inspect with the optional TLS-verify escape. $SKOPEO_INSPECT_ARGS is an intentional
# multi-flag list that must stay unquoted (and vanish when empty), so SC2086 is disabled here only.
# shellcheck disable=SC2086
skopeo_inspect() { skopeo inspect $SKOPEO_INSPECT_ARGS "$@"; }

require_script() {
	local path="$1"
	[[ -f "$path" ]] || die "missing script: $path"
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

require_rung_c_key_size() {
	local size
	size="$(file_size_bytes "$RUNG_C_KEY_FILE")"
	[[ "$size" == "32" ]] || die "rung-c image key must be exactly 32 bytes: $RUNG_C_KEY_FILE (${size} bytes)"
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

validate_manifest_env_values() {
	local manifest="$1"
	jq -e '
		def digest_ref: type == "string" and test("@sha256:[0-9a-f]{64}$");
		def nonempty: type == "string" and length > 0;
		(.rung_c.digest_ref | digest_ref) and
		(.rung_c.key_id | nonempty) and
		(.rung_c.key_file | nonempty) and
		(.rung_b.digest_ref | digest_ref) and
		(.rung_b.unsigned_digest_ref | digest_ref) and
		(.rung_b.cosign_pub | nonempty)
	' "$manifest" >/dev/null || die "manifest missing required rung b/c env fields or digest refs: $manifest"
}

emit_env_from_manifest() {
	local manifest="$1" line var value
	validate_manifest_env_values "$manifest"
	jq -r '
		[
			"RUNG_C_IMAGE=" + .rung_c.digest_ref,
			"RUNG_C_KEY_ID=" + .rung_c.key_id,
			"RUNG_C_KEY_FILE=" + .rung_c.key_file,
			"RUNG_B_IMAGE=" + .rung_b.digest_ref,
			"RUNG_B_UNSIGNED_IMAGE=" + .rung_b.unsigned_digest_ref,
			"RUNG_B_COSIGN_PUB=" + .rung_b.cosign_pub
		] | .[]
	' "$manifest" | while IFS= read -r line; do
		var="${line%%=*}"
		value="${line#*=}"
		printf 'export %s=' "$var"
		printf '%q\n' "$value"
	done
}

generate_rung_c_key() {
	if [[ -s "$RUNG_C_KEY_FILE" ]]; then
		return
	fi
	echo "Generating 32-byte rung-c image key: $RUNG_C_KEY_FILE"
	openssl rand 32 > "$RUNG_C_KEY_FILE"
	chmod 0600 "$RUNG_C_KEY_FILE"
}

ensure_cosign_keys() {
	if [[ -s "$COSIGN_KEY" && -s "$COSIGN_PUB" ]]; then
		return
	fi
	[[ -n "${COSIGN_PASSWORD:-}" ]] || die "set COSIGN_PASSWORD to generate/sign the rung-b key pair"
	echo "Generating cosign key pair under $ARTIFACT_DIR"
	(
		cd "$ARTIFACT_DIR"
		COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign generate-key-pair >/dev/null
	)
	[[ -s "$COSIGN_KEY" && -s "$COSIGN_PUB" ]] || die "cosign key generation did not create $COSIGN_KEY and $COSIGN_PUB"
	chmod 0600 "$COSIGN_KEY"
}

encrypt_rung_c() {
	local key_b64 oci_dir
	key_b64="$(base64 < "$RUNG_C_KEY_FILE" | tr -d '\n')"
	oci_dir="$ARTIFACT_DIR/oci"
	rm -rf "$oci_dir"
	mkdir -p "$oci_dir/input" "$oci_dir/output"

	echo "Copying source image to OCI dir: $SOURCE_IMAGE_REF"
	# shellcheck disable=SC2086
	skopeo copy $SKOPEO_COPY_ARGS "$SOURCE_IMAGE_REF" "dir:${oci_dir}/input"

	echo "Encrypting rung-c image with KID $RUNG_C_KEY_ID"
	"$CONTAINER_RUNTIME" run --rm \
		-v "${oci_dir}:/oci${CONTAINER_VOLUME_SUFFIX}" \
		"$COCO_KEYPROVIDER_IMAGE" \
		/encrypt.sh -k "$key_b64" -i "$RUNG_C_KEY_ID" -s dir:/oci/input -d dir:/oci/output

	skopeo inspect "dir:${oci_dir}/output" | jq -e --arg kid "$RUNG_C_KEY_ID" '
		[
			.LayersData[]?.Annotations["org.opencontainers.image.enc.keys.provider.attestation-agent"]?
			| select(. != null)
			| @base64d
			| fromjson
			| select(.kid == $kid)
		] | length > 0
	' >/dev/null

	echo "Pushing encrypted rung-c image: $RUNG_C_IMAGE"
	# shellcheck disable=SC2086
	skopeo copy $SKOPEO_COPY_ARGS "dir:${oci_dir}/output" "docker://${RUNG_C_IMAGE}"
}

sign_rung_b() {
	local c_digest c_digest_ref
	[[ -n "${COSIGN_PASSWORD:-}" ]] || die "set COSIGN_PASSWORD to sign the rung-b image"
	echo "Pushing unsigned rung-b negative-control image: $RUNG_B_UNSIGNED_IMAGE"
	# shellcheck disable=SC2086
	skopeo copy $SKOPEO_COPY_ARGS "$SOURCE_IMAGE_REF" "docker://${RUNG_B_UNSIGNED_IMAGE}"
	echo "Pushing rung-b image to sign: $RUNG_B_IMAGE"
	# shellcheck disable=SC2086
	skopeo copy $SKOPEO_COPY_ARGS "$SOURCE_IMAGE_REF" "docker://${RUNG_B_IMAGE}"
	c_digest="$(skopeo_inspect "docker://${RUNG_B_IMAGE}" | jq -r '.Digest')"
	c_digest_ref="$(image_digest_ref "$RUNG_B_IMAGE" "$c_digest")"
	echo "Signing rung-b image digest with $COSIGN_KEY: $c_digest_ref"
	# shellcheck disable=SC2086
	COSIGN_PASSWORD="$COSIGN_PASSWORD" cosign sign $COSIGN_SIGN_ARGS --key "$COSIGN_KEY" "$c_digest_ref"
	# shellcheck disable=SC2086
	cosign verify $COSIGN_VERIFY_ARGS --key "$COSIGN_PUB" "$c_digest_ref" >/dev/null
}

write_manifest() {
	local b_digest c_digest c_unsigned_digest b_digest_ref c_digest_ref c_unsigned_digest_ref b_key_sha c_pub_sha manifest env_file
	b_digest="$(skopeo_inspect "docker://${RUNG_C_IMAGE}" | jq -r '.Digest')"
	c_digest="$(skopeo_inspect "docker://${RUNG_B_IMAGE}" | jq -r '.Digest')"
	c_unsigned_digest="$(skopeo_inspect "docker://${RUNG_B_UNSIGNED_IMAGE}" | jq -r '.Digest')"
	b_digest_ref="$(image_digest_ref "$RUNG_C_IMAGE" "$b_digest")"
	c_digest_ref="$(image_digest_ref "$RUNG_B_IMAGE" "$c_digest")"
	c_unsigned_digest_ref="$(image_digest_ref "$RUNG_B_UNSIGNED_IMAGE" "$c_unsigned_digest")"
	b_key_sha="$(file_sha256 "$RUNG_C_KEY_FILE")"
	c_pub_sha="$(file_sha256 "$COSIGN_PUB")"
	manifest="$ARTIFACT_DIR/rung-bc-images.json"
	jq -n \
		--arg source "$SOURCE_IMAGE_REF" \
		--arg rung_c_image "$RUNG_C_IMAGE" \
		--arg rung_c_digest "$b_digest" \
		--arg rung_c_digest_ref "$b_digest_ref" \
		--arg rung_c_key_id "$RUNG_C_KEY_ID" \
		--arg rung_c_key_file "$RUNG_C_KEY_FILE" \
		--arg rung_c_key_sha256 "$b_key_sha" \
		--arg rung_b_image "$RUNG_B_IMAGE" \
		--arg rung_b_digest "$c_digest" \
		--arg rung_b_digest_ref "$c_digest_ref" \
		--arg rung_b_unsigned_image "$RUNG_B_UNSIGNED_IMAGE" \
		--arg rung_b_unsigned_digest "$c_unsigned_digest" \
		--arg rung_b_unsigned_digest_ref "$c_unsigned_digest_ref" \
		--arg cosign_pub "$COSIGN_PUB" \
		--arg cosign_pub_sha256 "$c_pub_sha" \
		'{
			source_image: $source,
			rung_c: {
				image: $rung_c_image,
				digest: $rung_c_digest,
				digest_ref: $rung_c_digest_ref,
				key_id: $rung_c_key_id,
				key_file: $rung_c_key_file,
				key_sha256: $rung_c_key_sha256
			},
			rung_b: {
				image: $rung_b_image,
				digest: $rung_b_digest,
				digest_ref: $rung_b_digest_ref,
				unsigned_image: $rung_b_unsigned_image,
				unsigned_digest: $rung_b_unsigned_digest,
				unsigned_digest_ref: $rung_b_unsigned_digest_ref,
				cosign_pub: $cosign_pub,
				cosign_pub_sha256: $cosign_pub_sha256
			}
		}' > "$manifest"
	echo "Wrote $manifest"
	env_file="$ARTIFACT_DIR/rung-bc.env"
	emit_env_from_manifest "$manifest" > "$env_file"
	echo "Wrote $env_file"
	jq -r '
		"RUNG_C_IMAGE=" + .rung_c.digest_ref,
		"RUNG_C_KEY_ID=" + .rung_c.key_id,
		"RUNG_C_KEY_FILE=" + .rung_c.key_file,
		"RUNG_B_IMAGE=" + .rung_b.digest_ref,
		"RUNG_B_UNSIGNED_IMAGE=" + .rung_b.unsigned_digest_ref,
		"RUNG_B_COSIGN_PUB=" + .rung_b.cosign_pub
	' "$manifest"
}

verify_built_artifacts() {
	local manifest="$ARTIFACT_DIR/rung-bc-images.json"
	if [[ "$VERIFY_RUNG_ARTIFACTS_AFTER_BUILD" == "0" ]]; then
		echo "Skipping post-build rung-b/c artifact verification."
		return
	fi
	require_script "$VERIFY_RUNG_C_KEY_WRAP_SCRIPT"
	require_script "$VERIFY_RUNG_B_SIGNATURE_SCRIPT"
	echo "Verifying built rung-c encrypted image metadata and key wrap"
	ARTIFACT_DIR="$ARTIFACT_DIR" RUNG_C_IMAGE="$RUNG_C_IMAGE" RUNG_C_KEY_ID="$RUNG_C_KEY_ID" \
		RUNG_C_KEY_FILE="$RUNG_C_KEY_FILE" RUNG_BC_IMAGES_MANIFEST="$manifest" \
		REQUIRE_RUNG_BC_IMAGES_MANIFEST=1 bash "$VERIFY_RUNG_C_KEY_WRAP_SCRIPT"
	echo "Verifying built rung-b signed image and unsigned negative control"
	ARTIFACT_DIR="$ARTIFACT_DIR" RUNG_B_IMAGE="$RUNG_B_IMAGE" RUNG_B_UNSIGNED_IMAGE="$RUNG_B_UNSIGNED_IMAGE" \
		RUNG_B_COSIGN_PUB="$COSIGN_PUB" RUNG_BC_IMAGES_MANIFEST="$manifest" COSIGN_VERIFY_ARGS="$COSIGN_VERIFY_ARGS" \
		REQUIRE_RUNG_BC_IMAGES_MANIFEST=1 bash "$VERIFY_RUNG_B_SIGNATURE_SCRIPT"
}

if [[ "${1:-}" == "digest-ref" ]]; then
	[[ "$#" -eq 3 ]] || die "usage: $0 digest-ref <image-ref> <sha256:digest>"
	image_digest_ref "$2" "$3"
	exit 0
fi

if [[ "${1:-}" == "file-sha256" ]]; then
	[[ "$#" -eq 2 ]] || die "usage: $0 file-sha256 <path>"
	need sha256sum
	file_sha256 "$2"
	exit 0
fi

if [[ "${1:-}" == "emit-env" ]]; then
	[[ "$#" -eq 2 ]] || die "usage: $0 emit-env <rung-bc-images.json>"
	need jq
	emit_env_from_manifest "$2"
	exit 0
fi

if [[ "${1:-}" == "default-cosign-sign-args" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 default-cosign-sign-args"
	default_cosign_sign_args
	exit 0
fi

if [[ "${1:-}" == "sign-rung-b-only" ]]; then
	# rung-b (signed image) WITHOUT rung-c: skopeo copy + cosign sign only, so it needs no
	# coco-keyprovider (which encrypts rung-c and may be unavailable in an air gap). Self-contained
	# — generates the cosign key pair if absent so `make build-rung-b` is a single step.
	[[ "$#" -eq 1 ]] || die "usage: $0 sign-rung-b-only"
	need skopeo
	need jq
	need cosign
	configure_cosign_args
	mkdir -p "$ARTIFACT_DIR"
	ensure_cosign_keys
	sign_rung_b
	# Emit the pushed DIGEST refs so `make deploy-trustee-rung-b` / `make run-rung-b-signed` need no
	# manual `skopeo inspect` — apply-rung-image.sh rejects non-@sha256 refs, and the make defaults
	# are the `:signed`/`:unsigned` TAGS. Source this file or read the digest refs from it.
	rb_digest="$(skopeo_inspect "docker://${RUNG_B_IMAGE}" | jq -r '.Digest')"
	ru_digest="$(skopeo_inspect "docker://${RUNG_B_UNSIGNED_IMAGE}" | jq -r '.Digest')"
	{
		echo "export RUNG_B_IMAGE=$(image_digest_ref "$RUNG_B_IMAGE" "$rb_digest")"
		echo "export RUNG_B_UNSIGNED_IMAGE=$(image_digest_ref "$RUNG_B_UNSIGNED_IMAGE" "$ru_digest")"
		echo "export RUNG_B_COSIGN_PUB=$COSIGN_PUB"
	} > "$ARTIFACT_DIR/rung-b.env"
	echo "Wrote $ARTIFACT_DIR/rung-b.env — 'source' it (or pass RUNG_B_IMAGE=<digest-ref>) before deploy-trustee-rung-b / run-rung-b-signed."
	exit 0
fi

need skopeo
need jq
need openssl
need base64
need cosign
need sha256sum
configure_cosign_args
detect_runtime
require_keyprovider_image

# Fail fast: rung-b signing always needs COSIGN_PASSWORD. Check it up front so we don't encrypt and
# push the rung-c image first and only then abort at the signing step (ensure_cosign_keys skips its
# own check when the key pair already exists).
[[ -n "${COSIGN_PASSWORD:-}" ]] || die "set COSIGN_PASSWORD (used to generate and sign the rung-b cosign key pair)"

mkdir -p "$ARTIFACT_DIR"
generate_rung_c_key
require_rung_c_key_size
ensure_cosign_keys
encrypt_rung_c
sign_rung_b
write_manifest
verify_built_artifacts
