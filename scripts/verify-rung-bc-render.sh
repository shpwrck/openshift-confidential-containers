#!/usr/bin/env bash
# Hardware-free checks for rung-b/c render paths. Safe for CI and local lint.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir=""

die() {
	echo "ERROR: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

cleanup() {
	[[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
}
trap cleanup EXIT

extract_initdata() {
	awk '$1 == "io.katacontainers.config.hypervisor.cc_init_data:" { print $2; found = 1; exit } END { exit found ? 0 : 1 }' "$1"
}

render_pod() {
	local rung="$1" out="$2" image="$3" name="$4" tamper="${5:-0}"
	local script
	case "$rung" in
		b) script="$REPO_ROOT/scripts/apply-rung-b.sh" ;;
		c) script="$REPO_ROOT/scripts/apply-rung-c.sh" ;;
		*) die "unknown rung: $rung" ;;
	esac
	env \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		MIRROR_REGISTRY="mirror.rig.local:8443" \
		RENDER_ONLY=1 \
		TAMPER_INITDATA="$tamper" \
		POD_NAME="$name" \
		"RUNG_${rung^^}_IMAGE=$image" \
		bash "$script" > "$out"
}

render_rung_a_pod() {
	local out="$1" image="$2" name="$3" namespace="$4" tamper="${5:-0}"
	env \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		MIRROR_REGISTRY="mirror.rig.local:8443" \
		NS="$namespace" \
		RENDER_ONLY=1 \
		TAMPER_INITDATA="$tamper" \
		POD_NAME="$name" \
		RUNG_A_IMAGE="$image" \
		bash "$REPO_ROOT/scripts/apply-rung-a.sh" > "$out"
}

expect_grep() {
	local pattern="$1" file="$2" label="$3"
	grep -Fq -- "$pattern" "$file" || die "$label not found: $pattern"
}

expect_digest_ref() {
	local image="$1" digest="$2" expected="$3" actual
	actual="$(bash "$REPO_ROOT/scripts/build-rung-images.sh" digest-ref "$image" "$digest")"
	[[ "$actual" == "$expected" ]] || die "digest-ref mismatch for $image: got $actual expected $expected"
}

verify_artifact_file_sha256() {
	local artifact="$tmpdir/artifact-fingerprint.txt" expected actual
	printf 'rung artifact fingerprint\n' > "$artifact"
	expected="$(sha256sum "$artifact" | awk '{print $1}')"
	actual="$(bash "$REPO_ROOT/scripts/build-rung-images.sh" file-sha256 "$artifact")"
	[[ "$actual" == "$expected" ]] || die "artifact sha256 mismatch: got $actual expected $expected"
}

verify_build_manifest_fingerprints() {
	local bin="$tmpdir/build-manifest-bin" artifacts="$tmpdir/build-manifest-artifacts" manifest
	local key_sha pub_sha
	mkdir -p "$bin" "$artifacts"
	printf '01234567890123456789012345678901' > "$artifacts/rung-b-image.key"
	printf 'cosign-public-key' > "$artifacts/cosign.pub"
	printf 'cosign-private-key' > "$artifacts/cosign.key"
	key_sha="$(sha256sum "$artifacts/rung-b-image.key" | awk '{print $1}')"
	pub_sha="$(sha256sum "$artifacts/cosign.pub" | awk '{print $1}')"

	cat > "$bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "image" && "${2:-}" == "exists" ]]; then
	exit 0
fi
if [[ "${1:-}" == "run" ]]; then
	exit 0
fi
exit 0
EOF
	chmod +x "$bin/podman"

	cat > "$bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
	copy) exit 0 ;;
	inspect)
		target="${2:-}"
		if [[ "$target" == dir:*output ]]; then
			kid_b64="$(printf '{"kid":"%s"}' "$TEST_RUNG_B_KEY_ID" | base64 -w0)"
			printf '{"LayersData":[{"Annotations":{"org.opencontainers.image.enc.keys.provider.attestation-agent":"%s"}}]}\n' "$kid_b64"
			exit 0
		fi
		case "$target" in
			*'rung-b:encrypted') digest='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
			*'rung-c:signed') digest='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' ;;
			*'rung-c:unsigned') digest='sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' ;;
			*) digest='sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ;;
		esac
		printf '{"Digest":"%s"}\n' "$digest"
		exit 0
		;;
esac
exit 1
EOF
	chmod +x "$bin/skopeo"

	cat > "$bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "sign" && "${2:-}" == "--help" ]]; then
	printf '%s\n' '      --tlog-upload bool'
	exit 0
fi
exit 0
EOF
	chmod +x "$bin/cosign"

	TEST_RUNG_B_KEY_ID="kbs:///default/image-key/rung-b" PATH="$bin:$PATH" \
		ARTIFACT_DIR="$artifacts" \
		CONTAINER_RUNTIME=podman \
		COSIGN_PASSWORD=test-password \
		SOURCE_IMAGE_REF="dir:/source-image" \
		RUNG_B_KEY_ID="kbs:///default/image-key/rung-b" \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b:encrypted" \
		RUNG_C_IMAGE="mirror.test.local:5000/coco/rung-c:signed" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c:unsigned" \
		bash "$REPO_ROOT/scripts/build-rung-images.sh" >/dev/null

	manifest="$artifacts/rung-bc-images.json"
	jq -e --arg key_sha "$key_sha" --arg pub_sha "$pub_sha" '
		.rung_b.key_sha256 == $key_sha and
		.rung_c.cosign_pub_sha256 == $pub_sha and
		.rung_b.digest_ref == "mirror.test.local:5000/coco/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
		.rung_c.digest_ref == "mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" and
		.rung_c.unsigned_digest_ref == "mirror.test.local:5000/coco/rung-c@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	' "$manifest" >/dev/null || die "rung-bc manifest did not include expected fingerprints and digest refs"
}

verify_apply_requires_digest_refs() {
	local err="$tmpdir/tagged-image.err"

	if MIRROR_CA="$tmpdir/mirror-ca.pem" RENDER_ONLY=1 \
		RUNG_B_IMAGE="mirror.rig.local:8443/coco/rung-b:encrypted" \
		bash "$REPO_ROOT/scripts/apply-rung-b.sh" > /dev/null 2> "$err"; then
		die "apply-rung-b accepted a tagged image reference"
	fi
	expect_grep "RUNG_B_IMAGE must be a sha256 digest ref" "$err" "rung-b digest-ref guard"
	expect_grep "rung-bc.env" "$err" "rung-b digest-ref env hint"

	if MIRROR_CA="$tmpdir/mirror-ca.pem" RENDER_ONLY=1 \
		RUNG_C_IMAGE="mirror.rig.local:8443/coco/rung-c:signed" \
		bash "$REPO_ROOT/scripts/apply-rung-c.sh" > /dev/null 2> "$err"; then
		die "apply-rung-c accepted a tagged image reference"
	fi
	expect_grep "RUNG_C_IMAGE must be a sha256 digest ref" "$err" "rung-c digest-ref guard"
	expect_grep "rung-bc.env" "$err" "rung-c digest-ref env hint"
}

verify_rung_b_key_size_guard() {
	local bin="$tmpdir/key-size-bin" invalid_key="$tmpdir/invalid-rung-b.key" err="$tmpdir/key-size.err"
	local hwid
	mkdir -p "$bin"
	printf 'too-short-key' > "$invalid_key"

	cat > "$bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "sign" && "${2:-}" == "--help" ]]; then
	printf '%s\n' '      --tlog-upload bool'
fi
exit 0
EOF
	chmod +x "$bin/cosign"

	cat > "$bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "image" && "${2:-}" == "exists" ]]; then
	exit 0
fi
exit 0
EOF
	chmod +x "$bin/podman"

	cat > "$bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
	chmod +x "$bin/skopeo"

	if PATH="$bin:$PATH" CONTAINER_RUNTIME=podman RUNG_B_KEY_FILE="$invalid_key" \
		ARTIFACT_DIR="$tmpdir/key-size-artifacts" \
		COSIGN_PASSWORD=test-password \
		bash "$REPO_ROOT/scripts/build-rung-images.sh" > /dev/null 2> "$err"; then
		die "build-rung-images accepted an invalid rung-b key size"
	fi
	expect_grep "rung-b image key must be exactly 32 bytes" "$err" "build rung-b key-size guard"

	cat > "$bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "whoami" ]]; then
	printf 'test-user\n'
fi
exit 0
EOF
	chmod +x "$bin/oc"

	hwid="$(printf 'f%.0s' {1..128})"
	mkdir -p "$tmpdir/key-size-vcek/$hwid"
	printf 'der' > "$tmpdir/key-size-vcek/$hwid/vcek.der"
	printf 'mirror-password' > "$tmpdir/mirror-password"
	printf 'kbs-pub' > "$tmpdir/kbs.pub"
	printf 'attestation-cert' > "$tmpdir/attestation.crt"

	if PATH="$bin:$PATH" \
		VCEK_BUNDLE="$tmpdir/key-size-vcek" \
		RENDER_KBSCONFIG_ONLY=1 \
		RUNG_B_KEY_FILE="$invalid_key" \
		bash "$REPO_ROOT/scripts/apply-trustee.sh" > /dev/null 2> "$err"; then
		die "apply-trustee accepted an invalid rung-b key size"
	fi
	expect_grep "rung-b image key must be exactly 32 bytes" "$err" "apply Trustee rung-b key-size guard"

	if PATH="$bin:$PATH" \
		VCEK_BUNDLE="$tmpdir/key-size-vcek" \
		MIRROR_PASSWORD_FILE="$tmpdir/mirror-password" \
		KBS_PUB="$tmpdir/kbs.pub" \
		ATTESTATION_CERT="$tmpdir/attestation.crt" \
		RUNG_B_KEY_FILE="$invalid_key" \
		bash "$REPO_ROOT/scripts/seed-trustee-secrets.sh" > /dev/null 2> "$err"; then
		die "seed-trustee-secrets accepted an invalid rung-b key size"
	fi
	expect_grep "rung-b image key must be exactly 32 bytes" "$err" "seed Trustee rung-b key-size guard"
}

verify_manifest_env_emit() {
	local manifest="$tmpdir/rung-bc-images.json" invalid_manifest="$tmpdir/rung-bc-images-invalid.json" env_file="$tmpdir/rung-bc.env" err="$tmpdir/rung-bc-env.err"
	cat > "$manifest" <<'EOF'
{
  "rung_b": {
    "digest_ref": "mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "key_file": "/tmp/rung artifacts/rung-b-image.key"
  },
  "rung_c": {
    "digest_ref": "mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "unsigned_digest_ref": "mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "cosign_pub": "/tmp/rung artifacts/cosign.pub"
  }
}
EOF
	bash "$REPO_ROOT/scripts/build-rung-images.sh" emit-env "$manifest" > "$env_file"
	expect_grep "export RUNG_B_IMAGE=" "$env_file" "rung-b env export"
	expect_grep "export RUNG_C_IMAGE=" "$env_file" "rung-c env export"
	expect_grep "export RUNG_C_UNSIGNED_IMAGE=" "$env_file" "rung-c unsigned env export"

	RUNG_ENV_FILE="$env_file" bash <<'EOF'
set -euo pipefail
# shellcheck source=/dev/null
source "$RUNG_ENV_FILE"
[[ "$RUNG_B_IMAGE" == "mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
[[ "$RUNG_B_KEY_FILE" == "/tmp/rung artifacts/rung-b-image.key" ]]
[[ "$RUNG_C_IMAGE" == "mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]]
[[ "$RUNG_C_UNSIGNED_IMAGE" == "mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" ]]
[[ "$RUNG_C_COSIGN_PUB" == "/tmp/rung artifacts/cosign.pub" ]]
EOF

	cat > "$invalid_manifest" <<'EOF'
{
  "rung_b": {
    "digest_ref": "mirror.test.local:5000/coco/rung-b:encrypted",
    "key_file": "/tmp/rung artifacts/rung-b-image.key"
  },
  "rung_c": {
    "digest_ref": "mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "unsigned_digest_ref": "mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "cosign_pub": "/tmp/rung artifacts/cosign.pub"
  }
}
EOF
	if bash "$REPO_ROOT/scripts/build-rung-images.sh" emit-env "$invalid_manifest" > /dev/null 2> "$err"; then
		die "emit-env accepted an invalid rung-b digest ref"
	fi
	expect_grep "manifest missing required rung b/c env fields or digest refs" "$err" "rung-b env manifest validation"
}

verify_cosign_default_sign_args() {
	local bin="$tmpdir/cosign-bin" actual
	mkdir -p "$bin"

	cat > "$bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "sign" && "${2:-}" == "--help" ]]; then
	cat <<'HELP'
      --new-bundle-format bool
      --use-signing-config bool
HELP
	exit 0
fi
exit 1
EOF
	chmod +x "$bin/cosign"
	actual="$(PATH="$bin:$PATH" bash "$REPO_ROOT/scripts/build-rung-images.sh" default-cosign-sign-args)"
	[[ "$actual" == "--yes --tlog-upload=false --new-bundle-format=false --use-signing-config=false" ]] || \
		die "cosign v3 default sign args mismatch: $actual"

	cat > "$bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "sign" && "${2:-}" == "--help" ]]; then
	cat <<'HELP'
      --tlog-upload bool
HELP
	exit 0
fi
exit 1
EOF
	chmod +x "$bin/cosign"
	actual="$(PATH="$bin:$PATH" bash "$REPO_ROOT/scripts/build-rung-images.sh" default-cosign-sign-args)"
	[[ "$actual" == "--yes --tlog-upload=false" ]] || die "cosign v2 default sign args mismatch: $actual"
}

verify_rung_c_digest_signing() {
	local bin="$tmpdir/rung-c-sign-bin" log="$tmpdir/rung-c-sign-calls"
	local digest signed_ref
	mkdir -p "$bin"
	digest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	signed_ref="mirror.test.local:5000/coco/rung-c@${digest}"

	cat > "$bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'skopeo' >> "$CALL_LOG"
for arg in "$@"; do
	printf '\t%s' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"

case "${1:-}" in
	copy) exit 0 ;;
	inspect)
		printf '{"Digest":"%s"}\n' "$TEST_DIGEST"
		exit 0
		;;
esac
exit 1
EOF
	chmod +x "$bin/skopeo"

	cat > "$bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cosign' >> "$CALL_LOG"
for arg in "$@"; do
	printf '\t%s' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"
exit 0
EOF
	chmod +x "$bin/cosign"

	CALL_LOG="$log" TEST_DIGEST="$digest" PATH="$bin:$PATH" \
		COSIGN_PASSWORD=test-password \
		COSIGN_KEY="$tmpdir/cosign.key" \
		COSIGN_PUB="$tmpdir/cosign.pub" \
		COSIGN_SIGN_ARGS="--yes --tlog-upload=false" \
		COSIGN_VERIFY_ARGS="--insecure-ignore-tlog=true" \
		SOURCE_IMAGE_REF="dir:/tmp/source-image" \
		RUNG_C_IMAGE="mirror.test.local:5000/coco/rung-c:signed" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c:unsigned" \
		bash "$REPO_ROOT/scripts/build-rung-images.sh" sign-rung-c-only >/dev/null

	expect_grep $'skopeo\tcopy\tdir:/tmp/source-image\tdocker://mirror.test.local:5000/coco/rung-c:unsigned' "$log" "rung-c unsigned image copy"
	expect_grep $'skopeo\tcopy\tdir:/tmp/source-image\tdocker://mirror.test.local:5000/coco/rung-c:signed' "$log" "rung-c signed image copy"
	expect_grep $'skopeo\tinspect\tdocker://mirror.test.local:5000/coco/rung-c:signed' "$log" "rung-c digest inspect"
	expect_grep $'cosign\tsign\t--yes\t--tlog-upload=false\t--key' "$log" "rung-c cosign sign"
	expect_grep "$signed_ref" "$log" "rung-c cosign signed digest ref"
	expect_grep $'cosign\tverify\t--insecure-ignore-tlog=true\t--key' "$log" "rung-c cosign verify"
}

verify_rung_c_policy_render() {
	local default_policy="$tmpdir/rung-c-policy-default.json" override_policy="$tmpdir/rung-c-policy-override.json"
	RUNG_C_IMAGE="mirror.test.local:5000/custom/path/rung-c:prod" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		bash "$REPO_ROOT/scripts/seed-trustee-secrets.sh" render-rung-c-policy > "$default_policy"

	jq -e '
		.default == [{"type":"reject"}] and
		.transports.docker["mirror.test.local:5000/custom/path/rung-c"][0].type == "sigstoreSigned" and
		.transports.docker["mirror.test.local:5000/custom/path/rung-c"][0].keyPath == "kbs:///default/sig-public-key/rung-c" and
		.transports.docker["mirror.test.local:5000/openshift/release"][0].type == "insecureAcceptAnything" and
		.transports.docker["mirror.test.local:5000/openshift/release-images"][0].type == "insecureAcceptAnything" and
		.transports.docker["mirror.test.local:5000/ubi9"][0].type == "insecureAcceptAnything"
	' "$default_policy" >/dev/null || die "default rung-c policy did not derive from RUNG_C_IMAGE"
	if jq -e '.transports.docker["mirror.rig.local:8443/coco/rung-c"]' "$default_policy" >/dev/null; then
		die "default rung-c policy unexpectedly kept the fallback image prefix"
	fi

	RUNG_C_IMAGE="mirror.test.local:5000/custom/path/rung-c@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
		RUNG_C_POLICY_IMAGE_PREFIX="mirror.test.local:5000/override/rung-c" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		bash "$REPO_ROOT/scripts/seed-trustee-secrets.sh" render-rung-c-policy > "$override_policy"
	jq -e '.transports.docker["mirror.test.local:5000/override/rung-c"][0].type == "sigstoreSigned"' "$override_policy" >/dev/null || \
		die "rung-c policy prefix override was not honored"
	if jq -e '.transports.docker["mirror.test.local:5000/custom/path/rung-c"]' "$override_policy" >/dev/null; then
		die "rung-c policy override render also included the derived image prefix"
	fi
}

verify_build_make_env() {
	local stub="$tmpdir/build-rung-images-stub.sh" out="$tmpdir/build-rung-images-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${COSIGN_PASSWORD+x}" ]]; then
	echo "COSIGN_PASSWORD leaked into build-rung-images recipe" >&2
	exit 1
fi

vars=(
	MIRROR_REGISTRY
	SOURCE_IMAGE
	SOURCE_IMAGE_REF
	ARTIFACT_DIR
	RUNG_B_IMAGE
	RUNG_C_IMAGE
	RUNG_C_UNSIGNED_IMAGE
	RUNG_B_KEY_PATH
	RUNG_B_KEY_ID
	RUNG_B_KEY_FILE
	COCO_KEYPROVIDER_IMAGE
	CONTAINER_RUNTIME
	CONTAINER_VOLUME_SUFFIX
	COSIGN_KEY
	COSIGN_PUB
	COSIGN_SIGN_ARGS
	COSIGN_VERIFY_ARGS
)

for var in "${vars[@]}"; do
	printf '%s=%s\n' "$var" "${!var}"
done
EOF
	chmod +x "$stub"

	make -s build-rung-images \
		BUILD_RUNG_IMAGES_SCRIPT="$stub" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		SOURCE_IMAGE="registry.example.com/base/app:1.0" \
		SOURCE_IMAGE_REF="dir:/tmp/source-image" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b:test" \
		RUNG_C_IMAGE="mirror.test.local:5000/coco/rung-c:test" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c:unsigned-test" \
		RUNG_B_KEY_PATH="/default/image-key/custom-rung-b" \
		RUNG_B_KEY_ID="kbs:///default/image-key/custom-rung-b" \
		RUNG_B_KEY_FILE="$tmpdir/custom-rung-b.key" \
		COCO_KEYPROVIDER_IMAGE="custom-keyprovider:local" \
		CONTAINER_RUNTIME="docker" \
		CONTAINER_VOLUME_SUFFIX=":cached" \
		COSIGN_KEY="$tmpdir/custom-cosign.key" \
		COSIGN_PUB="$tmpdir/custom-cosign.pub" \
		COSIGN_SIGN_ARGS="--yes --tlog-upload=false --allow-insecure-registry" \
		COSIGN_VERIFY_ARGS="--insecure-ignore-tlog=true --allow-insecure-registry" \
		> "$out"

	expect_grep "MIRROR_REGISTRY=mirror.test.local:5000" "$out" "Makefile mirror override"
	expect_grep "SOURCE_IMAGE=registry.example.com/base/app:1.0" "$out" "Makefile source image override"
	expect_grep "SOURCE_IMAGE_REF=dir:/tmp/source-image" "$out" "Makefile source ref override"
	expect_grep "ARTIFACT_DIR=$tmpdir/artifacts" "$out" "Makefile artifact dir override"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/coco/rung-b:test" "$out" "Makefile rung-b image override"
	expect_grep "RUNG_C_IMAGE=mirror.test.local:5000/coco/rung-c:test" "$out" "Makefile rung-c image override"
	expect_grep "RUNG_C_UNSIGNED_IMAGE=mirror.test.local:5000/coco/rung-c:unsigned-test" "$out" "Makefile rung-c unsigned image override"
	expect_grep "RUNG_B_KEY_PATH=/default/image-key/custom-rung-b" "$out" "Makefile rung-b key path override"
	expect_grep "RUNG_B_KEY_ID=kbs:///default/image-key/custom-rung-b" "$out" "Makefile rung-b key id override"
	expect_grep "RUNG_B_KEY_FILE=$tmpdir/custom-rung-b.key" "$out" "Makefile rung-b key file override"
	expect_grep "COCO_KEYPROVIDER_IMAGE=custom-keyprovider:local" "$out" "Makefile keyprovider image override"
	expect_grep "CONTAINER_RUNTIME=docker" "$out" "Makefile runtime override"
	expect_grep "CONTAINER_VOLUME_SUFFIX=:cached" "$out" "Makefile volume suffix override"
	expect_grep "COSIGN_KEY=$tmpdir/custom-cosign.key" "$out" "Makefile cosign key override"
	expect_grep "COSIGN_PUB=$tmpdir/custom-cosign.pub" "$out" "Makefile cosign pub override"
	expect_grep "COSIGN_SIGN_ARGS=--yes --tlog-upload=false --allow-insecure-registry" "$out" "Makefile cosign sign args override"
	expect_grep "COSIGN_VERIFY_ARGS=--insecure-ignore-tlog=true --allow-insecure-registry" "$out" "Makefile cosign verify args override"
}

verify_trustee_make_env() {
	local stub="$tmpdir/trustee-stub.sh" seed_out="$tmpdir/seed-rung-bc-env" apply_out="$tmpdir/apply-trustee-rung-bc-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vars=(
	NS
	VCEK_BUNDLE
	HWID
	HWIDS
	MIRROR_REGISTRY
	RUNG_B_KEY_FILE
	RUNG_C_IMAGE
	RUNG_C_COSIGN_PUB
	RUNG_C_POLICY_FILE
	RUNG_C_POLICY_IMAGE_PREFIX
)

for var in "${vars[@]}"; do
	printf '%s=%s\n' "$var" "${!var}"
done
EOF
	chmod +x "$stub"

	make -s seed-rung-bc-secrets \
		SEED_TRUSTEE_SECRETS_SCRIPT="$stub" \
		NS="trustee-test" \
		VCEK_BUNDLE="$tmpdir/vcek-bundle" \
		HWID="$(printf 'b%.0s' {1..128})" \
		HWIDS="$(printf 'c%.0s' {1..128})" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		RUNG_B_KEY_FILE="$tmpdir/rung-b.key" \
		RUNG_C_IMAGE="mirror.test.local:5000/custom/rung-c@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
		RUNG_C_COSIGN_PUB="$tmpdir/cosign.pub" \
		RUNG_C_POLICY_FILE="$tmpdir/policy.json" \
		RUNG_C_POLICY_IMAGE_PREFIX="mirror.test.local:5000/custom/rung-c" \
		> "$seed_out"

	make -s apply-trustee-rung-bc \
		APPLY_TRUSTEE_SCRIPT="$stub" \
		NS="trustee-test" \
		VCEK_BUNDLE="$tmpdir/vcek-bundle" \
		HWID="$(printf 'b%.0s' {1..128})" \
		HWIDS="$(printf 'c%.0s' {1..128})" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		RUNG_B_KEY_FILE="$tmpdir/rung-b.key" \
		RUNG_C_IMAGE="mirror.test.local:5000/custom/rung-c@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
		RUNG_C_COSIGN_PUB="$tmpdir/cosign.pub" \
		RUNG_C_POLICY_FILE="$tmpdir/policy.json" \
		RUNG_C_POLICY_IMAGE_PREFIX="mirror.test.local:5000/custom/rung-c" \
		> "$apply_out"

	for out in "$seed_out" "$apply_out"; do
		expect_grep "NS=trustee-test" "$out" "Makefile Trustee namespace override"
		expect_grep "VCEK_BUNDLE=$tmpdir/vcek-bundle" "$out" "Makefile Trustee VCEK bundle override"
		expect_grep "MIRROR_REGISTRY=mirror.test.local:5000" "$out" "Makefile Trustee mirror override"
		expect_grep "RUNG_B_KEY_FILE=$tmpdir/rung-b.key" "$out" "Makefile Trustee rung-b key override"
		expect_grep "RUNG_C_IMAGE=mirror.test.local:5000/custom/rung-c@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$out" "Makefile Trustee rung-c image override"
		expect_grep "RUNG_C_COSIGN_PUB=$tmpdir/cosign.pub" "$out" "Makefile Trustee cosign pub override"
		expect_grep "RUNG_C_POLICY_FILE=$tmpdir/policy.json" "$out" "Makefile Trustee policy file override"
		expect_grep "RUNG_C_POLICY_IMAGE_PREFIX=mirror.test.local:5000/custom/rung-c" "$out" "Makefile Trustee policy prefix override"
	done
}

verify_negative_test_make_env() {
	local stub="$tmpdir/negative-test-stub.sh" out="$tmpdir/negative-test-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARG=%s\n' "${1:-}"
vars=(
	NS
	TRUSTEE_NS
	MIRROR_REGISTRY
	MIRROR_DNS_UPSTREAM
	KBS_URL
	RUNG_B_IMAGE
	RUNG_C_UNSIGNED_IMAGE
	TIMEOUT
	KEEP_DENIED_PODS
)

for var in "${vars[@]}"; do
	printf '%s=%s\n' "$var" "${!var}"
done
EOF
	chmod +x "$stub"

	make -s negative-test \
		NEGATIVE_TEST_SCRIPT="$stub" \
		WHICH="rung-c" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		MIRROR_DNS_UPSTREAM="192.0.2.10" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_IMAGE="mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/custom/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		TIMEOUT="7" \
		KEEP_DENIED_PODS="1" \
		> "$out"

	expect_grep "ARG=rung-c" "$out" "Makefile negative-test target argument"
	expect_grep "NS=workload-test" "$out" "Makefile negative-test workload namespace"
	expect_grep "TRUSTEE_NS=trustee-test" "$out" "Makefile negative-test Trustee namespace"
	expect_grep "MIRROR_REGISTRY=mirror.test.local:5000" "$out" "Makefile negative-test mirror override"
	expect_grep "MIRROR_DNS_UPSTREAM=192.0.2.10" "$out" "Makefile negative-test DNS override"
	expect_grep "KBS_URL=http://kbs.trustee-test.svc:8080" "$out" "Makefile negative-test KBS URL override"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$out" "Makefile negative-test rung-b image override"
	expect_grep "RUNG_C_UNSIGNED_IMAGE=mirror.test.local:5000/custom/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$out" "Makefile negative-test rung-c unsigned override"
	expect_grep "TIMEOUT=7" "$out" "Makefile negative-test timeout override"
	expect_grep "KEEP_DENIED_PODS=1" "$out" "Makefile negative-test keep denied pods override"
}

verify_negative_test_scoped_denial_signals() {
	local bin="$tmpdir/scoped-denial-bin" policy_out="$tmpdir/rung-c-policy-denial.out" unrelated_out="$tmpdir/rung-c-unrelated-denial.out"
	mkdir -p "$bin"

	cat > "$bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]:-}" == "-n" ]]; then
	args=("${args[@]:2}")
fi
cmd="${args[0]:-}"
target="${args[1]:-}"

if [[ "$cmd" == "whoami" ]]; then
	printf 'test-user\n'
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "runtimeclass" ]]; then
	exit 0
fi
if [[ "$cmd" == "patch" ]]; then
	cat <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: negtest-rung-c
  namespace: workload-test
spec:
  runtimeClassName: kata-cc
YAML
	exit 0
fi
if [[ "$cmd" == "describe" && "$target" == "pod" ]]; then
	if [[ "${TEST_DENIAL_SIGNAL:-}" == "policy" ]]; then
		printf 'Warning: image policy rejected unsigned sigstore signature\n'
	else
		printf 'Warning: VCEK cache miss while checking unrelated attestation path\n'
	fi
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "events" ]]; then
	exit 0
fi
if [[ "$cmd" == "logs" ]]; then
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "pod" ]]; then
	exit 0
fi
if [[ "$cmd" == "delete" || "$cmd" == "apply" ]]; then
	exit 0
fi
exit 0
EOF
	chmod +x "$bin/oc"

	TEST_DENIAL_SIGNAL=policy PATH="$bin:$PATH" \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		TIMEOUT=0 \
		KEEP_DENIED_PODS=1 \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		bash "$REPO_ROOT/scripts/negative-test.sh" rung-c > "$policy_out"
	expect_grep "negative-test summary: 1 passed, 0 failed, 0 skipped." "$policy_out" "rung-c scoped policy denial summary"
	expect_grep "keeping denied pod 'negtest-rung-c' for evidence collection" "$policy_out" "negative-test keep denied pod message"

	if TEST_DENIAL_SIGNAL=unrelated PATH="$bin:$PATH" \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		TIMEOUT=0 \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		bash "$REPO_ROOT/scripts/negative-test.sh" rung-c > "$unrelated_out" 2>&1; then
		die "rung-c negative test accepted an unrelated denial signal"
	fi
	expect_grep "no rung-c signature/policy denial signal" "$unrelated_out" "rung-c unrelated denial rejection"
}

verify_workload_namespace_make_env() {
	local stub="$tmpdir/workload-target-stub.sh"
	local rung_b_out="$tmpdir/apply-rung-b-env" rung_c_out="$tmpdir/apply-rung-c-env" evidence_out="$tmpdir/collect-evidence-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vars=(
	NS
	TRUSTEE_NS
	MIRROR_REGISTRY
	MIRROR_DNS_UPSTREAM
	KBS_URL
	RUNG_A_IMAGE
	RUNG_B_IMAGE
	RUNG_C_IMAGE
	ARTIFACT_DIR
	EVIDENCE_DIR
	PODS
	RUNG_B_POD
	RUNG_C_POD
	NEG_RUNG_B_POD
	NEG_RUNG_C_POD
)

for var in "${vars[@]}"; do
	printf '%s=%s\n' "$var" "${!var-}"
done
EOF
	chmod +x "$stub"

	make -s apply-rung-a \
		APPLY_RUNG_A_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		MIRROR_DNS_UPSTREAM="192.0.2.10" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_A_IMAGE="mirror.test.local:5000/custom/rung-a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
		> "$tmpdir/apply-rung-a-env"

	make -s apply-rung-b \
		APPLY_RUNG_B_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		MIRROR_DNS_UPSTREAM="192.0.2.10" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_IMAGE="mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		> "$rung_b_out"

	make -s apply-rung-c \
		APPLY_RUNG_C_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		MIRROR_DNS_UPSTREAM="192.0.2.10" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_C_IMAGE="mirror.test.local:5000/custom/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		> "$rung_c_out"

	make -s collect-rung-bc-evidence \
		COLLECT_RUNG_BC_EVIDENCE_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		EVIDENCE_DIR="$tmpdir/evidence" \
		EVIDENCE_PODS="rung-a-secret negtest-air-gap custom-proof-pod" \
		RUNG_B_POD="custom-rung-b" \
		RUNG_C_POD="custom-rung-c" \
		NEG_RUNG_B_POD="custom-neg-rung-b" \
		NEG_RUNG_C_POD="custom-neg-rung-c" \
		> "$evidence_out"

	for out in "$tmpdir/apply-rung-a-env" "$rung_b_out" "$rung_c_out" "$evidence_out"; do
		expect_grep "NS=workload-test" "$out" "Makefile workload namespace override"
		expect_grep "TRUSTEE_NS=trustee-test" "$out" "Makefile Trustee namespace override"
	done
	expect_grep "RUNG_A_IMAGE=mirror.test.local:5000/custom/rung-a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmpdir/apply-rung-a-env" "Makefile apply-rung-a image override"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$rung_b_out" "Makefile apply-rung-b image override"
	expect_grep "RUNG_C_IMAGE=mirror.test.local:5000/custom/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$rung_c_out" "Makefile apply-rung-c image override"
	expect_grep "ARTIFACT_DIR=$tmpdir/artifacts" "$evidence_out" "Makefile evidence artifact dir override"
	expect_grep "EVIDENCE_DIR=$tmpdir/evidence" "$evidence_out" "Makefile evidence dir override"
	expect_grep "PODS=rung-a-secret negtest-air-gap custom-proof-pod" "$evidence_out" "Makefile evidence pod override"
	expect_grep "RUNG_B_POD=custom-rung-b" "$evidence_out" "Makefile evidence rung-b pod override"
	expect_grep "RUNG_C_POD=custom-rung-c" "$evidence_out" "Makefile evidence rung-c pod override"
	expect_grep "NEG_RUNG_B_POD=custom-neg-rung-b" "$evidence_out" "Makefile evidence negative rung-b pod override"
	expect_grep "NEG_RUNG_C_POD=custom-neg-rung-c" "$evidence_out" "Makefile evidence negative rung-c pod override"
}

verify_negative_test_air_gap_restores_vceks() {
	local bin="$tmpdir/air-gap-bin" log="$tmpdir/air-gap-oc-calls" out="$tmpdir/air-gap-negative-test.out"
	mkdir -p "$bin"

	cat > "$bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'oc' >> "$CALL_LOG"
for arg in "$@"; do
	printf '\t%s' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"

args=("$@")
if [[ "${args[0]:-}" == "-n" ]]; then
	args=("${args[@]:2}")
fi
cmd="${args[0]:-}"
target="${args[1]:-}"

if [[ "$cmd" == "whoami" ]]; then
	printf 'test-user\n'
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "runtimeclass" ]]; then
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "secret" ]]; then
	printf 'secret/vcek-snp-0\nsecret/vcek-snp-1\nsecret/credential\n'
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == secret/vcek-snp-* ]]; then
	name="${target#secret/}"
	cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
data:
  vcek.der: ZGVy
YAML
	exit 0
fi
if [[ "$cmd" == "patch" ]]; then
	cat <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: negtest-air-gap
  namespace: workload-test
spec:
  runtimeClassName: kata-cc
YAML
	exit 0
fi
if [[ "$cmd" == "describe" && "$target" == "pod" ]]; then
	printf 'Warning: attestation denied because VCEK cache is missing\n'
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "events" ]]; then
	printf 'attestation denied: VCEK cache missing\n'
	exit 0
fi
if [[ "$cmd" == "logs" ]]; then
	printf 'KBS OfflineStore VCEK cache miss\n'
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "pod" ]]; then
	exit 0
fi
if [[ "$cmd" == "delete" || "$cmd" == "apply" || "$cmd" == "rollout" ]]; then
	exit 0
fi
exit 0
EOF
	chmod +x "$bin/oc"

	CALL_LOG="$log" PATH="$bin:$PATH" \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		TIMEOUT=0 \
		bash "$REPO_ROOT/scripts/negative-test.sh" air-gap > "$out"

	expect_grep "negative-test summary: 1 passed, 0 failed, 0 skipped." "$out" "air-gap negative-test summary"
	expect_grep $'delete\tsecret/vcek-snp-0\tsecret/vcek-snp-1' "$log" "air-gap deleted all VCEK secrets"
	expect_grep "vcek-snp-0.yaml" "$log" "air-gap restored first VCEK secret"
	expect_grep "vcek-snp-1.yaml" "$log" "air-gap restored second VCEK secret"
}

verify_evidence_secret_redaction() {
	local raw="$tmpdir/raw-secret.json" redacted="$tmpdir/redacted-secret.json" lengths_raw="$tmpdir/lengths-secret.json" lengths="$tmpdir/secret-lengths.tsv"
	local fingerprints="$tmpdir/secret-fingerprints.tsv" expected_rung_b_sha expected_rung_c_sha
	cat > "$raw" <<'EOF'
{
  "apiVersion": "v1",
  "kind": "Secret",
  "type": "Opaque",
  "metadata": {
    "name": "image-key",
    "namespace": "trustee-operator-system",
    "labels": {"app": "trustee"},
    "annotations": {
      "kubectl.kubernetes.io/last-applied-configuration": "SECRET-DATA-SHOULD-NOT-SURVIVE",
      "example": "SECRET-ANNOTATION-VALUE-SHOULD-NOT-SURVIVE"
    }
  },
  "data": {
    "rung-b": "SECRET-KEY-SHOULD-NOT-SURVIVE"
  }
}
EOF
	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" redact-secret-json < "$raw" > "$redacted"
	jq -e '
		.kind == "Secret" and
		.metadata.name == "image-key" and
		.metadata.annotationKeys == ["example", "kubectl.kubernetes.io/last-applied-configuration"] and
		.dataKeys == ["rung-b"] and
		(.data | not) and
		(.metadata.annotations | not)
	' "$redacted" >/dev/null || die "secret redaction output shape is wrong"
	if grep -Fq "SECRET-" "$redacted"; then
		die "secret redaction leaked secret data or annotation values"
	fi

	cat > "$lengths_raw" <<'EOF'
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "image-key"
  },
  "data": {
    "rung-b": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=",
    "rung-c": "e30="
  }
}
EOF
	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" secret-data-lengths < "$lengths_raw" > "$lengths"
	expect_grep $'rung-b\t32' "$lengths" "secret data length for rung-b key"
	expect_grep $'rung-c\t2' "$lengths" "secret data length for policy data"

	expected_rung_b_sha="$(printf '01234567890123456789012345678901' | sha256sum | awk '{print $1}')"
	expected_rung_c_sha="$(printf '{}' | sha256sum | awk '{print $1}')"
	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" secret-data-fingerprints < "$lengths_raw" > "$fingerprints"
	expect_grep "rung-b	32	${expected_rung_b_sha}" "$fingerprints" "secret data fingerprint for rung-b key"
	expect_grep "rung-c	2	${expected_rung_c_sha}" "$fingerprints" "secret data fingerprint for rung-c policy"
}

verify_evidence_artifact_handoff() {
	local artifacts="$tmpdir/evidence-artifacts" evidence="$tmpdir/evidence-copy"
	mkdir -p "$artifacts"
	cat > "$artifacts/rung-bc-images.json" <<'EOF'
{"rung_b":{"digest_ref":"mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF
	cat > "$artifacts/rung-bc.env" <<'EOF'
export RUNG_B_IMAGE=mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF

	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" copy-artifact-handoff "$artifacts" "$evidence"
	cmp "$artifacts/rung-bc-images.json" "$evidence/rung-bc-images.json" >/dev/null || \
		die "evidence handoff did not copy rung-bc-images.json"
	cmp "$artifacts/rung-bc.env" "$evidence/rung-bc.env" >/dev/null || \
		die "evidence handoff did not copy rung-bc.env"
}

verify_evidence_summary_provenance() {
	local summary="$tmpdir/summary.env"
	NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		EVIDENCE_DIR="$tmpdir/evidence" \
		PODS="rung-a rung-b" \
		MIRROR_LOG_FILES="/tmp/mirror.log" \
		MIRROR_CONTAINER_NAMES="registry" \
		bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" write-summary "$summary"

	expect_grep "namespace=workload-test" "$summary" "evidence summary workload namespace"
	expect_grep "trustee_namespace=trustee-test" "$summary" "evidence summary Trustee namespace"
	expect_grep "repo_root=$REPO_ROOT" "$summary" "evidence summary repo root"
	expect_grep "repo_git_head=" "$summary" "evidence summary git head"
	expect_grep "repo_git_branch=" "$summary" "evidence summary git branch"
	expect_grep "repo_git_dirty=" "$summary" "evidence summary dirty state"
	expect_grep "tool_oc=" "$summary" "evidence summary oc path"
	expect_grep "tool_jq=" "$summary" "evidence summary jq path"
}

verify_evidence_pod_summary() {
	local pod_json="$tmpdir/pod-summary.json" summary="$tmpdir/pod-summary.tsv" index_row="$tmpdir/pod-index-row.tsv" missing_row="$tmpdir/pod-index-missing-row.tsv" expected_initdata_sha
	cat > "$pod_json" <<'EOF'
{
  "metadata": {
    "name": "rung-b-encrypted",
    "namespace": "workload-test",
    "annotations": {
      "io.katacontainers.config.hypervisor.cc_init_data": "dGVzdC1pbml0ZGF0YQ=="
    }
  },
  "spec": {
    "runtimeClassName": "kata-cc",
    "nodeName": "snp-worker-0",
    "containers": [
      {
        "name": "app",
        "image": "mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
    ]
  },
  "status": {
    "phase": "Running"
  }
}
EOF
	expected_initdata_sha="$(printf '%s' "dGVzdC1pbml0ZGF0YQ==" | sha256sum | awk '{print $1}')"
	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" pod-summary "$pod_json" > "$summary"
	expect_grep $'name\trung-b-encrypted' "$summary" "pod summary name"
	expect_grep $'namespace\tworkload-test' "$summary" "pod summary namespace"
	expect_grep $'phase\tRunning' "$summary" "pod summary phase"
	expect_grep $'runtime_class\tkata-cc' "$summary" "pod summary runtime class"
	expect_grep $'node_name\tsnp-worker-0' "$summary" "pod summary node"
	expect_grep $'app_image\tmirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$summary" "pod summary app image"
	expect_grep "initdata_b64_sha256	${expected_initdata_sha}" "$summary" "pod summary initdata hash"

	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" pod-index-row "$pod_json" requested-rung-b > "$index_row"
	expect_grep "requested-rung-b	present	rung-b-encrypted	workload-test	Running	kata-cc	snp-worker-0	mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	${expected_initdata_sha}" "$index_row" "pod summary index row"
	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" pod-index-missing-row missing-negtest > "$missing_row"
	expect_grep $'missing-negtest\tmissing' "$missing_row" "pod summary missing index row"
}

verify_evidence_rung_bc_proof_summary() {
	local evidence="$tmpdir/proof-evidence" manifest="$tmpdir/proof-rung-bc-images.json" out="$tmpdir/proof-summary.tsv"
	local rung_b_image rung_c_image rung_c_unsigned_image key_sha pub_sha
	rung_b_image="mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	rung_c_image="mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	rung_c_unsigned_image="mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	key_sha="$(printf '01234567890123456789012345678901' | sha256sum | awk '{print $1}')"
	pub_sha="$(printf 'cosign public key' | sha256sum | awk '{print $1}')"

	mkdir -p "$evidence/pods" "$evidence/trustee/secrets"
	cat > "$manifest" <<EOF
{
  "rung_b": {
    "digest_ref": "${rung_b_image}",
    "key_sha256": "${key_sha}"
  },
  "rung_c": {
    "digest_ref": "${rung_c_image}",
    "unsigned_digest_ref": "${rung_c_unsigned_image}",
    "cosign_pub_sha256": "${pub_sha}"
  }
}
EOF
	cat > "$evidence/trustee/secrets/rung-bc-fingerprints.tsv" <<EOF
secret	key	status	decoded_bytes	sha256
image-key	rung-b	present	32	${key_sha}
sig-public-key	rung-c	present	17	${pub_sha}
security-policy	rung-c	present	2	$(printf '{}' | sha256sum | awk '{print $1}')
EOF
	cat > "$evidence/pods/rung-b-encrypted.json" <<EOF
{"spec":{"containers":[{"name":"app","image":"${rung_b_image}"}]}}
EOF
	cat > "$evidence/pods/negtest-rung-b.json" <<EOF
{"spec":{"containers":[{"name":"app","image":"${rung_b_image}"}]}}
EOF
	cat > "$evidence/pods/rung-c-signed.json" <<EOF
{"spec":{"containers":[{"name":"app","image":"${rung_c_image}"}]}}
EOF
	cat > "$evidence/pods/negtest-rung-c.json" <<EOF
{"spec":{"containers":[{"name":"app","image":"${rung_c_unsigned_image}"}]}}
EOF

	bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" write-rung-bc-proof-summary "$manifest" "$evidence" "$out"
	expect_grep "rung_b_key_secret_sha256	${key_sha}	${key_sha}	match" "$out" "proof summary rung-b key fingerprint match"
	expect_grep "rung_c_pub_secret_sha256	${pub_sha}	${pub_sha}	match" "$out" "proof summary rung-c public key fingerprint match"
	expect_grep "rung_b_happy_image	${rung_b_image}	${rung_b_image}	match" "$out" "proof summary rung-b happy image match"
	expect_grep "rung_b_negative_image	${rung_b_image}	${rung_b_image}	match" "$out" "proof summary rung-b negative image match"
	expect_grep "rung_c_happy_image	${rung_c_image}	${rung_c_image}	match" "$out" "proof summary rung-c happy image match"
	expect_grep "rung_c_negative_unsigned_image	${rung_c_unsigned_image}	${rung_c_unsigned_image}	match" "$out" "proof summary rung-c negative image match"
}

write_valid_rung_bc_evidence_bundle() {
	local evidence="$1"
	local rung_b_image rung_c_image rung_c_unsigned_image key_sha pub_sha policy_sha
	rung_b_image="mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	rung_c_image="mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	rung_c_unsigned_image="mirror.test.local:5000/coco/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	key_sha="$(printf '01234567890123456789012345678901' | sha256sum | awk '{print $1}')"
	pub_sha="$(printf 'cosign public key' | sha256sum | awk '{print $1}')"
	policy_sha="$(printf '{}' | sha256sum | awk '{print $1}')"
	mkdir -p "$evidence/pods" "$evidence/trustee/secrets" "$evidence/trustee" "$evidence/cluster"

	cat > "$evidence/summary.env" <<'EOF'
captured_at_utc=2026-06-29T00:00:00Z
namespace=workload-test
trustee_namespace=trustee-test
repo_git_dirty=false
EOF
	cat > "$evidence/rung-bc-images.json" <<EOF
{
  "rung_b": {
    "digest_ref": "${rung_b_image}",
    "key_sha256": "${key_sha}"
  },
  "rung_c": {
    "digest_ref": "${rung_c_image}",
    "unsigned_digest_ref": "${rung_c_unsigned_image}",
    "cosign_pub_sha256": "${pub_sha}"
  }
}
EOF
	cat > "$evidence/rung-bc-proof-summary.tsv" <<EOF
check	expected	actual	status
rung_b_key_secret_sha256	${key_sha}	${key_sha}	match
rung_c_pub_secret_sha256	${pub_sha}	${pub_sha}	match
rung_b_happy_image	${rung_b_image}	${rung_b_image}	match
rung_b_negative_image	${rung_b_image}	${rung_b_image}	match
rung_c_happy_image	${rung_c_image}	${rung_c_image}	match
rung_c_negative_unsigned_image	${rung_c_unsigned_image}	${rung_c_unsigned_image}	match
EOF
	cat > "$evidence/trustee/secrets/rung-bc-fingerprints.tsv" <<EOF
secret	key	status	decoded_bytes	sha256
image-key	rung-b	present	32	${key_sha}
sig-public-key	rung-c	present	17	${pub_sha}
security-policy	rung-c	present	2	${policy_sha}
EOF
	cat > "$evidence/pods/summary.tsv" <<EOF
requested_pod	status	name	namespace	phase	runtime_class	node_name	app_image	initdata_b64_sha256
rung-b-encrypted	present	rung-b-encrypted	workload-test	Running	kata-cc	snp-worker-0	${rung_b_image}	initdata-a
rung-c-signed	present	rung-c-signed	workload-test	Running	kata-cc	snp-worker-0	${rung_c_image}	initdata-b
negtest-rung-b	present	negtest-rung-b	workload-test	Pending	kata-cc	snp-worker-0	${rung_b_image}	initdata-c
negtest-rung-c	present	negtest-rung-c	workload-test	Pending	kata-cc	snp-worker-0	${rung_c_unsigned_image}	initdata-d
EOF
	cat > "$evidence/trustee/logs.txt" <<'EOF'
GET /kbs/v0/resource/default/image-key/rung-b 200
GET /kbs/v0/resource/default/security-policy/rung-c 200
GET /kbs/v0/resource/default/sig-public-key/rung-c 200
rung-b measurement denied before releasing image-key
rung-c sigstore signature rejected by policy
EOF
	cat > "$evidence/pods/negtest-rung-b.describe.txt" <<'EOF'
Warning: attestation measurement denied; image-key/rung-b withheld
EOF
	cat > "$evidence/pods/negtest-rung-c.describe.txt" <<'EOF'
Warning: image security policy rejected unsigned sigstore signature
EOF
	: > "$evidence/trustee/events.txt"
	: > "$evidence/cluster/workload-events.txt"
}

verify_evidence_validation_gate() {
	local evidence="$tmpdir/valid-evidence" out="$tmpdir/validate-evidence.out" broken="$tmpdir/broken-evidence" err="$tmpdir/validate-evidence.err"
	write_valid_rung_bc_evidence_bundle "$evidence"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$evidence" > "$out"
	expect_grep "Rung b/c evidence validation OK." "$out" "valid evidence validation summary"

	cp -R "$evidence" "$broken"
	awk -F '\t' 'BEGIN { OFS = FS } $1 == "rung_c_happy_image" { $4 = "mismatch" } { print }' \
		"$broken/rung-bc-proof-summary.tsv" > "$broken/rung-bc-proof-summary.tsv.tmp"
	mv "$broken/rung-bc-proof-summary.tsv.tmp" "$broken/rung-bc-proof-summary.tsv"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken" > /dev/null 2> "$err"; then
		die "evidence validator accepted a mismatched proof summary"
	fi
	expect_grep "rung-bc proof summary has non-match rows" "$err" "evidence validator proof-summary failure"
}

verify_evidence_validation_make_env() {
	local stub="$tmpdir/validate-evidence-stub.sh" out="$tmpdir/validate-evidence-make-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARG=%s\n' "${1:-}"
vars=(
	EVIDENCE_DIR
	RUNG_B_POD
	RUNG_C_POD
	NEG_RUNG_B_POD
	NEG_RUNG_C_POD
)
for var in "${vars[@]}"; do
	printf '%s=%s\n' "$var" "${!var-}"
done
EOF
	chmod +x "$stub"
	make -s validate-rung-bc-evidence \
		VALIDATE_RUNG_BC_EVIDENCE_SCRIPT="$stub" \
		EVIDENCE_DIR="$tmpdir/evidence-for-validation" \
		RUNG_B_POD="custom-rung-b" \
		RUNG_C_POD="custom-rung-c" \
		NEG_RUNG_B_POD="custom-neg-rung-b" \
		NEG_RUNG_C_POD="custom-neg-rung-c" \
		> "$out"
	expect_grep "ARG=$tmpdir/evidence-for-validation" "$out" "Makefile validate evidence directory argument"
	expect_grep "EVIDENCE_DIR=$tmpdir/evidence-for-validation" "$out" "Makefile validate evidence dir env"
	expect_grep "RUNG_B_POD=custom-rung-b" "$out" "Makefile validate rung-b pod override"
	expect_grep "RUNG_C_POD=custom-rung-c" "$out" "Makefile validate rung-c pod override"
	expect_grep "NEG_RUNG_B_POD=custom-neg-rung-b" "$out" "Makefile validate negative rung-b pod override"
	expect_grep "NEG_RUNG_C_POD=custom-neg-rung-c" "$out" "Makefile validate negative rung-c pod override"
}

need make
need oc
need jq

cd "$REPO_ROOT"
tmpdir="$(mktemp -d)"
cat > "$tmpdir/mirror-ca.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
EOF

rung_b_image="mirror.rig.local:8443/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
rung_c_image="mirror.rig.local:8443/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
rung_a_image="mirror.rig.local:8443/ubi9/ubi-minimal@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
digest="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

expect_digest_ref "mirror.rig.local:8443/coco/rung-b:encrypted" "$digest" "mirror.rig.local:8443/coco/rung-b@$digest"
expect_digest_ref "mirror.rig.local:8443/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$digest" "mirror.rig.local:8443/coco/rung-b@$digest"
expect_digest_ref "mirror.rig.local:8443/coco/rung-b" "$digest" "mirror.rig.local:8443/coco/rung-b@$digest"
verify_artifact_file_sha256
verify_build_manifest_fingerprints
verify_apply_requires_digest_refs
verify_rung_b_key_size_guard
verify_manifest_env_emit
verify_cosign_default_sign_args
verify_rung_c_digest_signing
verify_rung_c_policy_render
verify_build_make_env
verify_trustee_make_env
verify_negative_test_make_env
verify_negative_test_scoped_denial_signals
verify_workload_namespace_make_env
verify_negative_test_air_gap_restores_vceks
verify_evidence_secret_redaction
verify_evidence_artifact_handoff
verify_evidence_summary_provenance
verify_evidence_pod_summary
verify_evidence_rung_bc_proof_summary
verify_evidence_validation_gate
verify_evidence_validation_make_env

render_pod b "$tmpdir/rung-b.yaml" "$rung_b_image" rung-b-render
render_pod b "$tmpdir/rung-b-tampered.yaml" "$rung_b_image" negtest-rung-b 1
render_pod c "$tmpdir/rung-c.yaml" "$rung_c_image" rung-c-render
render_rung_a_pod "$tmpdir/rung-a.yaml" "$rung_a_image" rung-a-render workload-render
render_rung_a_pod "$tmpdir/rung-a-tampered.yaml" "$rung_a_image" negtest-rung-a workload-render 1

expect_grep "name: rung-a-render" "$tmpdir/rung-a.yaml" "rung-a pod name"
expect_grep "namespace: workload-render" "$tmpdir/rung-a.yaml" "rung-a workload namespace"
expect_grep "image: $rung_a_image" "$tmpdir/rung-a.yaml" "rung-a image"
expect_grep "runtimeClassName: kata-cc" "$tmpdir/rung-a.yaml" "rung-a runtimeClass"
expect_grep "cdh/resource/default/attestation-status/status" "$tmpdir/rung-a.yaml" "rung-a attestation resource path"
expect_grep "name: rung-b-render" "$tmpdir/rung-b.yaml" "rung-b pod name"
expect_grep "image: $rung_b_image" "$tmpdir/rung-b.yaml" "rung-b image"
expect_grep "runtimeClassName: kata-cc" "$tmpdir/rung-b.yaml" "rung-b runtimeClass"
expect_grep "name: rung-c-render" "$tmpdir/rung-c.yaml" "rung-c pod name"
expect_grep "image: $rung_c_image" "$tmpdir/rung-c.yaml" "rung-c image"
expect_grep "runtimeClassName: kata-cc" "$tmpdir/rung-c.yaml" "rung-c runtimeClass"

a_initdata="$(extract_initdata "$tmpdir/rung-a.yaml")"
a_tampered_initdata="$(extract_initdata "$tmpdir/rung-a-tampered.yaml")"
b_initdata="$(extract_initdata "$tmpdir/rung-b.yaml")"
b_tampered_initdata="$(extract_initdata "$tmpdir/rung-b-tampered.yaml")"
c_initdata="$(extract_initdata "$tmpdir/rung-c.yaml")"
[[ "$a_initdata" != "$a_tampered_initdata" ]] || die "tampered rung-a initdata did not change the measured annotation"
[[ "$b_initdata" != "$b_tampered_initdata" ]] || die "tampered rung-b initdata did not change the measured annotation"

a_decoded="$tmpdir/rung-a-initdata.toml"
b_decoded="$tmpdir/rung-b-initdata.toml"
c_decoded="$tmpdir/rung-c-initdata.toml"
a_tampered_decoded="$tmpdir/rung-a-tampered-initdata.toml"
b_tampered_decoded="$tmpdir/rung-b-tampered-initdata.toml"
bash "$REPO_ROOT/scripts/encode-initdata.sh" decode "$a_initdata" > "$a_decoded"
bash "$REPO_ROOT/scripts/encode-initdata.sh" decode "$a_tampered_initdata" > "$a_tampered_decoded"
bash "$REPO_ROOT/scripts/encode-initdata.sh" decode "$b_initdata" > "$b_decoded"
bash "$REPO_ROOT/scripts/encode-initdata.sh" decode "$b_tampered_initdata" > "$b_tampered_decoded"
bash "$REPO_ROOT/scripts/encode-initdata.sh" decode "$c_initdata" > "$c_decoded"
expect_grep 'image_security_policy_uri = "kbs:///default/security-policy/test"' "$a_decoded" "rung-a policy URI"
expect_grep 'image_security_policy_uri = "kbs:///default/security-policy/test"' "$b_decoded" "rung-b policy URI"
expect_grep 'image_security_policy_uri = "kbs:///default/security-policy/rung-c"' "$c_decoded" "rung-c policy URI"
expect_grep '# negative-test tamper: changes SNP HOST_DATA; do not regenerate RVPS' "$a_tampered_decoded" "rung-a tamper marker"
expect_grep '# negative-test tamper: changes SNP HOST_DATA; do not regenerate RVPS' "$b_tampered_decoded" "rung-b tamper marker"

hwid="$(printf 'a%.0s' {1..128})"
mkdir -p "$tmpdir/vcek/$hwid"
printf 'der' > "$tmpdir/vcek/$hwid/vcek.der"
head -c 32 /dev/zero > "$tmpdir/rung-b.key"
printf 'pub' > "$tmpdir/cosign.pub"

VCEK_BUNDLE="$tmpdir/vcek" RENDER_KBSCONFIG_ONLY=1 \
	bash "$REPO_ROOT/scripts/apply-trustee.sh" > "$tmpdir/kbsconfig-base.yaml"
if grep -Eq '^[[:space:]]+- (image-key|sig-public-key)[[:space:]]*$' "$tmpdir/kbsconfig-base.yaml"; then
	die "base Trustee render unexpectedly included rung-b/c secret resources"
fi

VCEK_BUNDLE="$tmpdir/vcek" \
	RUNG_B_KEY_FILE="$tmpdir/rung-b.key" \
	RUNG_C_COSIGN_PUB="$tmpdir/cosign.pub" \
	RENDER_KBSCONFIG_ONLY=1 \
	bash "$REPO_ROOT/scripts/apply-trustee.sh" > "$tmpdir/kbsconfig-rung-bc.yaml"
expect_grep "mountPath: /opt/confidential-containers/attestation-service/kds-store/vcek/$hwid" "$tmpdir/kbsconfig-rung-bc.yaml" "rendered HWID mount path"
grep -Eq '^[[:space:]]+- image-key[[:space:]]*$' "$tmpdir/kbsconfig-rung-bc.yaml" || die "rendered KbsConfig missing image-key"
grep -Eq '^[[:space:]]+- sig-public-key[[:space:]]*$' "$tmpdir/kbsconfig-rung-bc.yaml" || die "rendered KbsConfig missing sig-public-key"

echo "rung b/c render checks OK"
