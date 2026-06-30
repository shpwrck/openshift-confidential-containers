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

verify_deterministic_initdata_encoding() {
	local first="$tmpdir/initdata-first.toml" second="$tmpdir/initdata-second.toml" first_encoded second_encoded
	printf 'algorithm = "sha256"\nversion = "0.1.0"\n' > "$first"
	cp "$first" "$second"
	first_encoded="$(bash "$REPO_ROOT/scripts/encode-initdata.sh" encode "$first")"
	second_encoded="$(bash "$REPO_ROOT/scripts/encode-initdata.sh" encode "$second")"
	[[ "$first_encoded" == "$second_encoded" ]] || die "initdata encoding should be deterministic for identical TOML"
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
		.rung_b.key_id == "kbs:///default/image-key/rung-b" and
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
    "key_id": "kbs:///default/image-key/rung-b",
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
	expect_grep "export RUNG_B_KEY_ID=" "$env_file" "rung-b key ID env export"
	expect_grep "export RUNG_C_IMAGE=" "$env_file" "rung-c env export"
	expect_grep "export RUNG_C_UNSIGNED_IMAGE=" "$env_file" "rung-c unsigned env export"

	RUNG_ENV_FILE="$env_file" bash <<'EOF'
set -euo pipefail
# shellcheck source=/dev/null
source "$RUNG_ENV_FILE"
[[ "$RUNG_B_IMAGE" == "mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
[[ "$RUNG_B_KEY_ID" == "kbs:///default/image-key/rung-b" ]]
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

verify_gen_rvps_veritas_local_command() {
	local bin="$tmpdir/gen-rvps-bin" log="$tmpdir/gen-rvps-podman.log" out="$tmpdir/rvps-snp.yaml"
	local pull_secret="$tmpdir/pull-secret.json" initdata="$tmpdir/initdata.toml"
	local registries="$tmpdir/registries.conf" wrapper="$tmpdir/oc-wrapper"
	mkdir -p "$bin"
	printf '{}\n' > "$pull_secret"
	printf 'algorithm = "sha256"\nversion = "0.1.0"\n' > "$initdata"
	printf '[[registry]]\nprefix = "quay.io/openshift-release-dev/ocp-release"\n' > "$registries"
	printf '#!/usr/bin/env bash\nexec /usr/local/bin/oc "$@"\n' > "$wrapper"
	chmod +x "$wrapper"

	cat > "$bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman' >> "$CALL_LOG"
outdir=""
while [[ "$#" -gt 0 ]]; do
	printf '\t%s' "$1" >> "$CALL_LOG"
	if [[ "$1" == "-v" ]]; then
		printf '\t%s' "${2:-}" >> "$CALL_LOG"
		case "${2:-}" in
			*:/veritas-out:*) outdir="${2%%:/veritas-out:*}" ;;
		esac
		shift 2
		continue
	fi
	if [[ "$1" == "-e" ]]; then
		printf '\t%s' "${2:-}" >> "$CALL_LOG"
		shift 2
		continue
	fi
	shift
done
printf '\n' >> "$CALL_LOG"
[[ -n "$outdir" ]] || { echo "missing /veritas-out mount" >&2; exit 1; }
mkdir -p "$outdir"
cat > "$outdir/rvps-reference-values.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rvps-reference-values
data:
  reference-values.json: |
    []
YAML
EOF
	chmod +x "$bin/podman"

	CALL_LOG="$log" PATH="$bin:$PATH" \
		make -s -C "$REPO_ROOT" gen-rvps \
		PULL_SECRET="$pull_secret" \
		INITDATA="$initdata" \
		RVPS_OUT="$out" \
		OCP_VERSION="4.20.18" \
		REGISTRIES_CONF="$registries" \
		VERITAS_OC_WRAPPER="$wrapper" \
		>/dev/null

	expect_grep "kind: ConfigMap" "$out" "gen-rvps copied Veritas output file"
	expect_grep "quay.io/openshift_sandboxed_containers/coco-tools@sha256:89c219d2c7cb8359e8cc86605df1d31ce3be0f2565683b8bff882dba0c8e2605" "$log" "gen-rvps pinned tools image"
	expect_grep $'--ocp-version\t4.20.18' "$log" "gen-rvps OCP version flag"
	expect_grep "/etc/containers/registries.conf:ro,z" "$log" "gen-rvps registries.conf mount"
	expect_grep "/veritas-bin:ro,z" "$log" "gen-rvps oc wrapper mount"
	expect_grep $'-o\t/veritas-out' "$log" "gen-rvps output directory"
}

verify_rung_b_measurement_policy_render() {
	local initdata="$tmpdir/rung-b-policy-initdata.toml" placeholder="$tmpdir/rung-b-policy-placeholder.toml"
	local wrong_algorithm="$tmpdir/rung-b-policy-wrong-algorithm.toml"
	local out="$tmpdir/rung-b-measurement-policy.yaml" err="$tmpdir/rung-b-measurement-policy.err"
	local expected_sha
	cat > "$initdata" <<'EOF'
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.kbs]
url = "http://kbs-service.trustee-operator-system.svc:8080"
'''
EOF
	expected_sha="$(sha256sum "$initdata" | awk '{print $1}')"

	NS="trustee-test" \
		RUNG_B_KEY_ID="kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c" \
		bash "$REPO_ROOT/scripts/render-rung-b-measurement-policy.sh" "$initdata" > "$out"

	expect_grep "namespace: trustee-test" "$out" "rung-b measurement policy namespace"
	expect_grep "input.init_data == \"$expected_sha\"" "$out" "rung-b measurement policy HOST_DATA hash"
	expect_grep 'image_key_path := ["default","image-kek","380af3e3-69f8-4985-9196-e9261a19072c"]' "$out" "rung-b measurement policy key path"
	expect_grep 'input["submods"][sm]["ear.trustworthiness-vector"]["configuration"] == 2' "$out" "rung-b measurement policy EAR TV path"
	if grep -Fq 'ear.status.configuration' "$out"; then
		die "rung-b measurement policy used the stale ear.status.configuration path"
	fi

	printf 'algorithm = "sha256"\n[data]\n"aa.toml" = "__KBS_URL__"\n' > "$placeholder"
	if bash "$REPO_ROOT/scripts/render-rung-b-measurement-policy.sh" "$placeholder" > /dev/null 2> "$err"; then
		die "rung-b measurement policy renderer accepted unresolved placeholders"
	fi
	expect_grep "unresolved initdata placeholders" "$err" "rung-b measurement policy placeholder guard"

	printf 'algorithm = "sha384"\nversion = "0.1.0"\n' > "$wrong_algorithm"
	if bash "$REPO_ROOT/scripts/render-rung-b-measurement-policy.sh" "$wrong_algorithm" > /dev/null 2> "$err"; then
		die "rung-b measurement policy renderer accepted non-sha256 initdata"
	fi
	expect_grep 'must declare algorithm = "sha256"' "$err" "rung-b measurement policy algorithm guard"
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

	expect_grep $'skopeo\tcopy\t--remove-signatures\tdir:/tmp/source-image\tdocker://mirror.test.local:5000/coco/rung-c:unsigned' "$log" "rung-c unsigned image copy"
	expect_grep $'skopeo\tcopy\t--remove-signatures\tdir:/tmp/source-image\tdocker://mirror.test.local:5000/coco/rung-c:signed' "$log" "rung-c signed image copy"
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
	SKOPEO_COPY_ARGS
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
		SKOPEO_COPY_ARGS="--remove-signatures --dest-tls-verify=false" \
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
	expect_grep "SKOPEO_COPY_ARGS=--remove-signatures --dest-tls-verify=false" "$out" "Makefile skopeo copy args override"
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
	RUNG_B_KEY_ID
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
		RUNG_B_KEY_ID="kbs:///default/custom-image-kek/custom-rung-b" \
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
		RUNG_B_KEY_ID="kbs:///default/custom-image-kek/custom-rung-b" \
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
		expect_grep "RUNG_B_KEY_ID=kbs:///default/custom-image-kek/custom-rung-b" "$out" "Makefile Trustee rung-b key ID override"
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
	RUNG_B_POLICY_URI
	RUNG_C_POLICY_URI
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
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_C_POLICY_URI="kbs:///custom/security-policy/rung-c" \
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
	expect_grep "RUNG_B_POLICY_URI=kbs:///custom/security-policy/rung-b" "$out" "Makefile negative-test rung-b policy URI override"
	expect_grep "RUNG_C_POLICY_URI=kbs:///custom/security-policy/rung-c" "$out" "Makefile negative-test rung-c policy URI override"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$out" "Makefile negative-test rung-b image override"
	expect_grep "RUNG_C_UNSIGNED_IMAGE=mirror.test.local:5000/custom/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$out" "Makefile negative-test rung-c unsigned override"
	expect_grep "TIMEOUT=7" "$out" "Makefile negative-test timeout override"
	expect_grep "KEEP_DENIED_PODS=1" "$out" "Makefile negative-test keep denied pods override"
}

verify_negative_test_scoped_denial_signals() {
	local bin="$tmpdir/scoped-denial-bin"
	local policy_out="$tmpdir/rung-c-policy-denial.out" unrelated_out="$tmpdir/rung-c-unrelated-denial.out"
	local rung_b_denial_out="$tmpdir/rung-b-attestation-denial.out" rung_b_host_out="$tmpdir/rung-b-host-decrypt.out"
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
	case "${TEST_DENIAL_SIGNAL:-}" in
		policy)
			printf 'Warning: image policy rejected unsigned sigstore signature\n'
			;;
		rung-b-attestation)
			printf 'Warning: attestation failed: measurement mismatch while requesting resource/default/image-kek/uuid HTTP/1.1" 403\n'
			;;
		host-decrypt)
			printf 'Failed to pull image: layer sha256:abc should be decrypted, but we cannot modify the manifest: Destination specifies a digest\n'
			;;
		*)
			printf 'Warning: VCEK cache miss while checking unrelated attestation path\n'
			;;
	esac
	exit 0
fi
if [[ "$cmd" == "get" && "$target" == "events" ]]; then
	exit 0
fi
if [[ "$cmd" == "logs" ]]; then
	if [[ "${TEST_DENIAL_SIGNAL:-}" == "stale-rung-b" ]]; then
		[[ "$target" == "deployment/trustee-deployment" ]] || exit 0
		for arg in "${args[@]}"; do
			[[ "$arg" == --since-time=* ]] && exit 0
		done
		printf '10.128.0.86 "GET /kbs/v0/resource/default/image-kek/uuid HTTP/1.1" 401\n'
	fi
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

	TEST_DENIAL_SIGNAL=rung-b-attestation PATH="$bin:$PATH" \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		TIMEOUT=0 \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		bash "$REPO_ROOT/scripts/negative-test.sh" rung-b > "$rung_b_denial_out"
	expect_grep "negative-test summary: 1 passed, 0 failed, 0 skipped." "$rung_b_denial_out" "rung-b scoped attestation denial summary"

	if TEST_DENIAL_SIGNAL=host-decrypt PATH="$bin:$PATH" \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		TIMEOUT=0 \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		bash "$REPO_ROOT/scripts/negative-test.sh" rung-b > "$rung_b_host_out" 2>&1; then
		die "rung-b negative test accepted a host-side encrypted-layer pull failure"
	fi
	expect_grep "no rung-b attestation/image-key denial signal" "$rung_b_host_out" "rung-b host decrypt failure rejection"

	if TEST_DENIAL_SIGNAL=stale-rung-b PATH="$bin:$PATH" \
		MIRROR_CA="$tmpdir/mirror-ca.pem" \
		NS="workload-test" \
		TRUSTEE_NS="trustee-test" \
		TIMEOUT=0 \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		bash "$REPO_ROOT/scripts/negative-test.sh" rung-b > "$rung_b_host_out" 2>&1; then
		die "rung-b negative test accepted a stale Trustee denial from an older probe"
	fi
	expect_grep "no rung-b attestation/image-key denial signal" "$rung_b_host_out" "rung-b stale Trustee denial rejection"

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
	local rung_b_out="$tmpdir/apply-rung-b-env" rung_c_out="$tmpdir/apply-rung-c-env"
	local evidence_out="$tmpdir/collect-evidence-env" diagnose_out="$tmpdir/diagnose-rung-b-direct-pull-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vars=(
	NS
	TRUSTEE_NS
	MIRROR_REGISTRY
	MIRROR_DNS_UPSTREAM
	KBS_URL
	RUNG_B_KEY_ID
	IMAGE_SECURITY_POLICY_URI
	RUNG_B_POLICY_URI
	RUNG_C_POLICY_URI
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
	RUNG_B_APP_LOG_MARKER
	RUNG_C_APP_LOG_MARKER
	TRUSTEE_LOG_TAIL
	POD_LOG_TAIL
	MIRROR_LOG_TAIL
	MIRROR_LOG_FILES
	MIRROR_CONTAINER_NAMES
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
		RUNG_B_KEY_ID="kbs:///default/custom-image-key/rung-b" \
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_B_IMAGE="mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		> "$rung_b_out"

	make -s apply-rung-c \
		APPLY_RUNG_C_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		MIRROR_DNS_UPSTREAM="192.0.2.10" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_C_POLICY_URI="kbs:///custom/security-policy/rung-c" \
		RUNG_C_IMAGE="mirror.test.local:5000/custom/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		> "$rung_c_out"

	make -s collect-rung-bc-evidence \
		COLLECT_RUNG_BC_EVIDENCE_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_KEY_ID="kbs:///default/custom-image-key/rung-b" \
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_C_POLICY_URI="kbs:///custom/security-policy/rung-c" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		EVIDENCE_DIR="$tmpdir/evidence" \
		EVIDENCE_PODS="rung-a-secret negtest-air-gap custom-proof-pod" \
		RUNG_B_POD="custom-rung-b" \
		RUNG_C_POD="custom-rung-c" \
		NEG_RUNG_B_POD="custom-neg-rung-b" \
		NEG_RUNG_C_POD="custom-neg-rung-c" \
		RUNG_B_APP_LOG_MARKER="custom rung-b proof marker" \
		RUNG_C_APP_LOG_MARKER="custom rung-c proof marker" \
		TRUSTEE_LOG_TAIL="111" \
		POD_LOG_TAIL="222" \
		MIRROR_LOG_TAIL="333" \
		MIRROR_LOG_FILES="/var/log/custom-mirror.log /srv/mirror/access.log" \
		MIRROR_CONTAINER_NAMES="quay-app custom-registry" \
		> "$evidence_out"

	make -s diagnose-rung-b-direct-pull \
		DIAGNOSE_RUNG_B_DIRECT_PULL_SCRIPT="$stub" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		MIRROR_REGISTRY="mirror.test.local:5000" \
		MIRROR_DNS_UPSTREAM="192.0.2.10" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_KEY_ID="kbs:///default/custom-image-key/rung-b" \
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_B_IMAGE="mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		MIRROR_LOG_TAIL="333" \
		MIRROR_LOG_FILES="/var/log/custom-mirror.log /srv/mirror/access.log" \
		MIRROR_CONTAINER_NAMES="quay-app custom-registry" \
		> "$diagnose_out"

	for out in "$tmpdir/apply-rung-a-env" "$rung_b_out" "$rung_c_out" "$evidence_out" "$diagnose_out"; do
		expect_grep "NS=workload-test" "$out" "Makefile workload namespace override"
		expect_grep "TRUSTEE_NS=trustee-test" "$out" "Makefile Trustee namespace override"
	done
	expect_grep "RUNG_A_IMAGE=mirror.test.local:5000/custom/rung-a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmpdir/apply-rung-a-env" "Makefile apply-rung-a image override"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$rung_b_out" "Makefile apply-rung-b image override"
	expect_grep "RUNG_C_IMAGE=mirror.test.local:5000/custom/rung-c@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$rung_c_out" "Makefile apply-rung-c image override"
	expect_grep "IMAGE_SECURITY_POLICY_URI=kbs:///custom/security-policy/rung-b" "$rung_b_out" "Makefile apply-rung-b policy URI override"
	expect_grep "IMAGE_SECURITY_POLICY_URI=kbs:///custom/security-policy/rung-c" "$rung_c_out" "Makefile apply-rung-c policy URI override"
	expect_grep "ARTIFACT_DIR=$tmpdir/artifacts" "$evidence_out" "Makefile evidence artifact dir override"
	expect_grep "EVIDENCE_DIR=$tmpdir/evidence" "$evidence_out" "Makefile evidence dir override"
	expect_grep "KBS_URL=http://kbs.trustee-test.svc:8080" "$evidence_out" "Makefile evidence KBS URL override"
	expect_grep "RUNG_B_KEY_ID=kbs:///default/custom-image-key/rung-b" "$evidence_out" "Makefile evidence rung-b key ID override"
	expect_grep "RUNG_B_POLICY_URI=kbs:///custom/security-policy/rung-b" "$evidence_out" "Makefile evidence rung-b policy URI override"
	expect_grep "RUNG_C_POLICY_URI=kbs:///custom/security-policy/rung-c" "$evidence_out" "Makefile evidence rung-c policy URI override"
	expect_grep "PODS=rung-a-secret negtest-air-gap custom-proof-pod" "$evidence_out" "Makefile evidence pod override"
	expect_grep "RUNG_B_POD=custom-rung-b" "$evidence_out" "Makefile evidence rung-b pod override"
	expect_grep "RUNG_C_POD=custom-rung-c" "$evidence_out" "Makefile evidence rung-c pod override"
	expect_grep "NEG_RUNG_B_POD=custom-neg-rung-b" "$evidence_out" "Makefile evidence negative rung-b pod override"
	expect_grep "NEG_RUNG_C_POD=custom-neg-rung-c" "$evidence_out" "Makefile evidence negative rung-c pod override"
	expect_grep "RUNG_B_APP_LOG_MARKER=custom rung-b proof marker" "$evidence_out" "Makefile evidence rung-b app marker override"
	expect_grep "RUNG_C_APP_LOG_MARKER=custom rung-c proof marker" "$evidence_out" "Makefile evidence rung-c app marker override"
	expect_grep "TRUSTEE_LOG_TAIL=111" "$evidence_out" "Makefile evidence Trustee log tail override"
	expect_grep "POD_LOG_TAIL=222" "$evidence_out" "Makefile evidence pod log tail override"
	expect_grep "MIRROR_LOG_TAIL=333" "$evidence_out" "Makefile evidence mirror log tail override"
	expect_grep "MIRROR_LOG_FILES=/var/log/custom-mirror.log /srv/mirror/access.log" "$evidence_out" "Makefile evidence mirror log file override"
	expect_grep "MIRROR_CONTAINER_NAMES=quay-app custom-registry" "$evidence_out" "Makefile evidence mirror container override"
	expect_grep "ARTIFACT_DIR=$tmpdir/artifacts" "$diagnose_out" "Makefile diagnose artifact dir override"
	expect_grep "KBS_URL=http://kbs.trustee-test.svc:8080" "$diagnose_out" "Makefile diagnose KBS URL override"
	expect_grep "RUNG_B_KEY_ID=kbs:///default/custom-image-key/rung-b" "$diagnose_out" "Makefile diagnose rung-b key ID override"
	expect_grep "RUNG_B_POLICY_URI=kbs:///custom/security-policy/rung-b" "$diagnose_out" "Makefile diagnose rung-b policy URI override"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/custom/rung-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$diagnose_out" "Makefile diagnose rung-b image override"
	expect_grep "MIRROR_LOG_TAIL=333" "$diagnose_out" "Makefile diagnose mirror log tail override"
	expect_grep "MIRROR_LOG_FILES=/var/log/custom-mirror.log /srv/mirror/access.log" "$diagnose_out" "Makefile diagnose mirror log file override"
	expect_grep "MIRROR_CONTAINER_NAMES=quay-app custom-registry" "$diagnose_out" "Makefile diagnose mirror container override"
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
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_KEY_ID="kbs:///default/custom-image-key/rung-b" \
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_C_POLICY_URI="kbs:///custom/security-policy/rung-c" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		EVIDENCE_DIR="$tmpdir/evidence" \
		PODS="rung-a rung-b" \
		RUNG_B_POD="custom-rung-b" \
		RUNG_C_POD="custom-rung-c" \
		NEG_RUNG_B_POD="custom-neg-rung-b" \
		NEG_RUNG_C_POD="custom-neg-rung-c" \
		RUNG_B_APP_LOG_MARKER="custom rung-b proof marker" \
		RUNG_C_APP_LOG_MARKER="custom rung-c proof marker" \
		MIRROR_LOG_FILES="/tmp/mirror.log" \
		MIRROR_CONTAINER_NAMES="registry" \
		bash "$REPO_ROOT/scripts/collect-rung-bc-evidence.sh" write-summary "$summary"

	expect_grep "namespace=workload-test" "$summary" "evidence summary workload namespace"
	expect_grep "trustee_namespace=trustee-test" "$summary" "evidence summary Trustee namespace"
	expect_grep "kbs_url=http://kbs.trustee-test.svc:8080" "$summary" "evidence summary KBS URL"
	expect_grep "rung_b_key_id=kbs:///default/custom-image-key/rung-b" "$summary" "evidence summary rung-b key ID"
	expect_grep "rung_b_policy_uri=kbs:///custom/security-policy/rung-b" "$summary" "evidence summary rung-b policy URI"
	expect_grep "rung_c_policy_uri=kbs:///custom/security-policy/rung-c" "$summary" "evidence summary rung-c policy URI"
	expect_grep "repo_root=$REPO_ROOT" "$summary" "evidence summary repo root"
	expect_grep "repo_git_head=" "$summary" "evidence summary git head"
	expect_grep "repo_git_branch=" "$summary" "evidence summary git branch"
	expect_grep "repo_git_dirty=" "$summary" "evidence summary dirty state"
	expect_grep "rung_b_pod=custom-rung-b" "$summary" "evidence summary rung-b pod role"
	expect_grep "rung_c_pod=custom-rung-c" "$summary" "evidence summary rung-c pod role"
	expect_grep "neg_rung_b_pod=custom-neg-rung-b" "$summary" "evidence summary negative rung-b pod role"
	expect_grep "neg_rung_c_pod=custom-neg-rung-c" "$summary" "evidence summary negative rung-c pod role"
	expect_grep "rung_b_app_log_marker=custom rung-b proof marker" "$summary" "evidence summary rung-b app marker"
	expect_grep "rung_c_app_log_marker=custom rung-c proof marker" "$summary" "evidence summary rung-c app marker"
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
	rung_c_unsigned_image="mirror.test.local:5000/coco/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	key_sha="$(printf '01234567890123456789012345678901' | sha256sum | awk '{print $1}')"
	pub_sha="$(printf 'cosign public key' | sha256sum | awk '{print $1}')"
	policy_sha="$(printf '{}' | sha256sum | awk '{print $1}')"
	mkdir -p "$evidence/pods" "$evidence/trustee/secrets" "$evidence/trustee" "$evidence/cluster" "$evidence/mirror/files"

	cat > "$evidence/summary.env" <<'EOF'
captured_at_utc=2026-06-29T00:00:00Z
namespace=workload-test
trustee_namespace=trustee-test
kbs_url=http://kbs.trustee-test.svc:8080
rung_b_key_id=kbs:///default/image-key/rung-b
rung_b_policy_uri=kbs:///default/security-policy/test
rung_c_policy_uri=kbs:///default/security-policy/rung-c
repo_git_dirty=false
rung_b_pod=rung-b-encrypted
rung_c_pod=rung-c-signed
neg_rung_b_pod=negtest-rung-b
neg_rung_c_pod=negtest-rung-c
rung_b_app_log_marker=rung-b: encrypted image decrypted and running
rung_c_app_log_marker=rung-c: signed image accepted and running
EOF
	cat > "$evidence/rung-bc-images.json" <<EOF
{
  "rung_b": {
    "digest_ref": "${rung_b_image}",
    "key_id": "kbs:///default/image-key/rung-b",
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
negtest-rung-c	present	negtest-rung-c	workload-test	Pending	kata-cc	snp-worker-0	${rung_c_unsigned_image}	initdata-b
EOF
	cat > "$evidence/pods/rung-b-encrypted.json" <<EOF
{
  "spec": {
    "containers": [
      {
        "name": "app",
        "image": "${rung_b_image}"
      }
    ]
  },
  "status": {
    "phase": "Running",
    "conditions": [
      {
        "type": "Ready",
        "status": "True"
      },
      {
        "type": "ContainersReady",
        "status": "True"
      }
    ],
    "containerStatuses": [
      {
        "name": "app",
        "ready": true,
        "started": true,
        "state": {
          "running": {
            "startedAt": "2026-06-29T00:01:00Z"
          }
        }
      }
    ]
  }
}
EOF
	cat > "$evidence/pods/rung-c-signed.json" <<EOF
{
  "spec": {
    "containers": [
      {
        "name": "app",
        "image": "${rung_c_image}"
      }
    ]
  },
  "status": {
    "phase": "Running",
    "conditions": [
      {
        "type": "Ready",
        "status": "True"
      },
      {
        "type": "ContainersReady",
        "status": "True"
      }
    ],
    "containerStatuses": [
      {
        "name": "app",
        "ready": true,
        "started": true,
        "state": {
          "running": {
            "startedAt": "2026-06-29T00:01:00Z"
          }
        }
      }
    ]
  }
}
EOF
	cat > "$evidence/pods/negtest-rung-b.json" <<EOF
{
  "spec": {
    "containers": [
      {
        "name": "app",
        "image": "${rung_b_image}"
      }
    ]
  },
  "status": {
    "phase": "Pending",
    "containerStatuses": [
      {
        "name": "app",
        "ready": false,
        "started": false,
        "state": {
          "waiting": {
            "reason": "CreateContainerError"
          }
        }
      }
    ]
  }
}
EOF
	cat > "$evidence/pods/negtest-rung-c.json" <<EOF
{
  "spec": {
    "containers": [
      {
        "name": "app",
        "image": "${rung_c_unsigned_image}"
      }
    ]
  },
  "status": {
    "phase": "Pending",
    "containerStatuses": [
      {
        "name": "app",
        "ready": false,
        "started": false,
        "state": {
          "waiting": {
            "reason": "CreateContainerError"
          }
        }
      }
    ]
  }
}
EOF
	cat > "$evidence/pods/rung-b-encrypted.logs.txt" <<'EOF'
app rung-b: encrypted image decrypted and running
EOF
	cat > "$evidence/pods/rung-c-signed.logs.txt" <<'EOF'
app rung-c: signed image accepted and running
EOF
	cat > "$evidence/pods/rung-b-encrypted.initdata.toml" <<'EOF'
[token_configs.kbs]
url = "http://kbs.trustee-test.svc:8080"
[kbc]
url = "http://kbs.trustee-test.svc:8080"
[image]
image_security_policy_uri = "kbs:///default/security-policy/test"
EOF
	cat > "$evidence/pods/rung-c-signed.initdata.toml" <<'EOF'
[token_configs.kbs]
url = "http://kbs.trustee-test.svc:8080"
[kbc]
url = "http://kbs.trustee-test.svc:8080"
[image]
image_security_policy_uri = "kbs:///default/security-policy/rung-c"
EOF
	cat > "$evidence/pods/negtest-rung-b.initdata.toml" <<'EOF'
[token_configs.kbs]
url = "http://kbs.trustee-test.svc:8080"
[kbc]
url = "http://kbs.trustee-test.svc:8080"
[image]
image_security_policy_uri = "kbs:///default/security-policy/test"

# negative-test tamper: changes SNP HOST_DATA; do not regenerate RVPS
EOF
	cat > "$evidence/pods/negtest-rung-c.initdata.toml" <<'EOF'
[token_configs.kbs]
url = "http://kbs.trustee-test.svc:8080"
[kbc]
url = "http://kbs.trustee-test.svc:8080"
[image]
image_security_policy_uri = "kbs:///default/security-policy/rung-c"
EOF
	: > "$evidence/pods/rung-b-encrypted.initdata.decode.err"
	: > "$evidence/pods/rung-c-signed.initdata.decode.err"
	: > "$evidence/pods/negtest-rung-b.initdata.decode.err"
	: > "$evidence/pods/negtest-rung-c.initdata.decode.err"
	cat > "$evidence/trustee/logs.txt" <<'EOF'
GET /kbs/v0/resource/default/image-key/rung-b 200
GET /kbs/v0/resource/default/security-policy/rung-c 200
GET /kbs/v0/resource/default/sig-public-key/rung-c 200
rung-b measurement denied before releasing image-key
rung-c sigstore signature rejected by policy
EOF
	cat > "$evidence/mirror/files/access.log" <<'EOF'
10.0.0.10 - - "GET /v2/coco/rung-b/manifests/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1" 200 "-" "oci-client/0.15.0"
10.0.0.10 - - "GET /v2/coco/rung-b/blobs/sha256:abababababababababababababababababababababababababababababababab HTTP/1.1" 200 "-" "oci-client/0.15.0"
10.0.0.10 - - "GET /v2/coco/rung-c/manifests/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb HTTP/1.1" 200 "-" "oci-client/0.15.0"
10.0.0.10 - - "GET /v2/coco/rung-c/blobs/sha256:bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc HTTP/1.1" 200 "-" "oci-client/0.15.0"
10.0.0.10 - - "GET /v2/coco/rung-c-unsigned/manifests/sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc HTTP/1.1" 200 "-" "oci-client/0.15.0"
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
	local evidence="$tmpdir/valid-evidence" out="$tmpdir/validate-evidence.out"
	local broken="$tmpdir/broken-evidence" err="$tmpdir/validate-evidence.err"
	local broken_missing_proof="$tmpdir/broken-missing-proof-row-evidence" missing_proof_err="$tmpdir/validate-missing-proof-row-evidence.err"
	local broken_key_id="$tmpdir/broken-key-id-evidence" key_id_err="$tmpdir/validate-key-id-evidence.err"
	local broken_mirror="$tmpdir/broken-mirror-evidence" mirror_err="$tmpdir/validate-mirror-evidence.err"
	local broken_digest="$tmpdir/broken-mirror-digest-evidence" digest_err="$tmpdir/validate-mirror-digest-evidence.err"
	local broken_guest_pull="$tmpdir/broken-guest-pull-evidence" guest_pull_err="$tmpdir/validate-guest-pull-evidence.err"
	local broken_blob_pull="$tmpdir/broken-blob-pull-evidence" blob_pull_err="$tmpdir/validate-blob-pull-evidence.err"
	local broken_b_initdata="$tmpdir/broken-b-initdata-evidence" b_initdata_err="$tmpdir/validate-b-initdata-evidence.err"
	local broken_c_initdata="$tmpdir/broken-c-initdata-evidence" c_initdata_err="$tmpdir/validate-c-initdata-evidence.err"
	local broken_decoded_initdata="$tmpdir/broken-decoded-initdata-evidence" decoded_initdata_err="$tmpdir/validate-decoded-initdata-evidence.err"
	local broken_kbs_url="$tmpdir/broken-kbs-url-evidence" kbs_url_err="$tmpdir/validate-kbs-url-evidence.err"
	local broken_app_log="$tmpdir/broken-app-log-evidence" app_log_err="$tmpdir/validate-app-log-evidence.err"
	local status_app_start="$tmpdir/status-app-start-evidence" status_app_start_out="$tmpdir/validate-status-app-start-evidence.out"
	local custom_app_log="$tmpdir/custom-app-log-evidence" custom_app_log_out="$tmpdir/validate-custom-app-log-evidence.out"
	local custom_pods="$tmpdir/custom-pods-evidence" custom_pods_out="$tmpdir/validate-custom-pods-evidence.out"
	local custom_key_id="$tmpdir/custom-key-id-evidence" custom_key_id_out="$tmpdir/validate-custom-key-id-evidence.out"
	local custom_policy_uri="$tmpdir/custom-policy-uri-evidence" custom_policy_uri_out="$tmpdir/validate-custom-policy-uri-evidence.out"
	write_valid_rung_bc_evidence_bundle "$evidence"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$evidence" > "$out"
	expect_grep "Rung b/c evidence validation OK." "$out" "valid evidence validation summary"

	cp -R "$evidence" "$status_app_start"
	printf '$ oc -n workload-test logs pod/rung-b-encrypted --all-containers --prefix=true --tail=200\n' > "$status_app_start/pods/rung-b-encrypted.logs.txt"
	printf '$ oc -n workload-test logs pod/rung-c-signed --all-containers --prefix=true --tail=200\n' > "$status_app_start/pods/rung-c-signed.logs.txt"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$status_app_start" > "$status_app_start_out"
	expect_grep "rung-b app start proven by pod status" "$status_app_start_out" "status-based rung-b app-start validation"
	expect_grep "rung-c app start proven by pod status" "$status_app_start_out" "status-based rung-c app-start validation"

	cp -R "$evidence" "$custom_app_log"
	sed -i \
		-e 's/^rung_b_app_log_marker=.*/rung_b_app_log_marker=custom rung-b proof marker/' \
		-e 's/^rung_c_app_log_marker=.*/rung_c_app_log_marker=custom rung-c proof marker/' \
		"$custom_app_log/summary.env"
	printf 'app custom rung-b proof marker\n' > "$custom_app_log/pods/rung-b-encrypted.logs.txt"
	printf 'app custom rung-c proof marker\n' > "$custom_app_log/pods/rung-c-signed.logs.txt"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$custom_app_log" > "$custom_app_log_out"
	expect_grep "Rung b/c evidence validation OK." "$custom_app_log_out" "summary app marker validation"

	cp -R "$evidence" "$custom_pods"
	mv "$custom_pods/pods/rung-b-encrypted.logs.txt" "$custom_pods/pods/custom-rung-b.logs.txt"
	mv "$custom_pods/pods/rung-c-signed.logs.txt" "$custom_pods/pods/custom-rung-c.logs.txt"
	mv "$custom_pods/pods/rung-b-encrypted.initdata.toml" "$custom_pods/pods/custom-rung-b.initdata.toml"
	mv "$custom_pods/pods/rung-c-signed.initdata.toml" "$custom_pods/pods/custom-rung-c.initdata.toml"
	mv "$custom_pods/pods/negtest-rung-b.initdata.toml" "$custom_pods/pods/custom-neg-rung-b.initdata.toml"
	mv "$custom_pods/pods/negtest-rung-c.initdata.toml" "$custom_pods/pods/custom-neg-rung-c.initdata.toml"
	mv "$custom_pods/pods/rung-b-encrypted.initdata.decode.err" "$custom_pods/pods/custom-rung-b.initdata.decode.err"
	mv "$custom_pods/pods/rung-c-signed.initdata.decode.err" "$custom_pods/pods/custom-rung-c.initdata.decode.err"
	mv "$custom_pods/pods/negtest-rung-b.initdata.decode.err" "$custom_pods/pods/custom-neg-rung-b.initdata.decode.err"
	mv "$custom_pods/pods/negtest-rung-c.initdata.decode.err" "$custom_pods/pods/custom-neg-rung-c.initdata.decode.err"
	mv "$custom_pods/pods/negtest-rung-b.describe.txt" "$custom_pods/pods/custom-neg-rung-b.describe.txt"
	mv "$custom_pods/pods/negtest-rung-c.describe.txt" "$custom_pods/pods/custom-neg-rung-c.describe.txt"
	sed -i \
		-e 's/^rung_b_pod=.*/rung_b_pod=custom-rung-b/' \
		-e 's/^rung_c_pod=.*/rung_c_pod=custom-rung-c/' \
		-e 's/^neg_rung_b_pod=.*/neg_rung_b_pod=custom-neg-rung-b/' \
		-e 's/^neg_rung_c_pod=.*/neg_rung_c_pod=custom-neg-rung-c/' \
		"$custom_pods/summary.env"
	sed -i \
		-e 's/rung-b-encrypted/custom-rung-b/g' \
		-e 's/rung-c-signed/custom-rung-c/g' \
		-e 's/negtest-rung-b/custom-neg-rung-b/g' \
		-e 's/negtest-rung-c/custom-neg-rung-c/g' \
		"$custom_pods/pods/summary.tsv"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$custom_pods" > "$custom_pods_out"
	expect_grep "Rung b/c evidence validation OK." "$custom_pods_out" "summary pod-role validation"

	cp -R "$evidence" "$custom_key_id"
	sed -i \
		-e 's#^rung_b_key_id=.*#rung_b_key_id=kbs:///default/custom-image-key/rung-b#' \
		-e 's#resource/default/image-key/rung-b#resource/default/custom-image-key/rung-b#' \
		"$custom_key_id/summary.env" \
		"$custom_key_id/trustee/logs.txt"
	sed -i 's#^image-key	rung-b#custom-image-key	rung-b#' \
		"$custom_key_id/trustee/secrets/rung-bc-fingerprints.tsv"
	jq '.rung_b.key_id = "kbs:///default/custom-image-key/rung-b"' \
		"$custom_key_id/rung-bc-images.json" > "$custom_key_id/rung-bc-images.json.tmp"
	mv "$custom_key_id/rung-bc-images.json.tmp" "$custom_key_id/rung-bc-images.json"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$custom_key_id" > "$custom_key_id_out"
	expect_grep "Trustee logs include resource/default/custom-image-key/rung-b" "$custom_key_id_out" "summary rung-b custom key ID validation"

	cp -R "$evidence" "$custom_policy_uri"
	sed -i 's#^rung_c_policy_uri=.*#rung_c_policy_uri=kbs:///custom/security-policy/rung-c#' \
		"$custom_policy_uri/summary.env"
	sed -i 's#kbs:///default/security-policy/rung-c#kbs:///custom/security-policy/rung-c#g' \
		"$custom_policy_uri/pods/rung-c-signed.initdata.toml" \
		"$custom_policy_uri/pods/negtest-rung-c.initdata.toml"
	sed -i 's#resource/default/security-policy/rung-c#resource/custom/security-policy/rung-c#' \
		"$custom_policy_uri/trustee/logs.txt"
	bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$custom_policy_uri" > "$custom_policy_uri_out"
	expect_grep "Trustee logs include resource/custom/security-policy/rung-c" "$custom_policy_uri_out" "summary rung-c custom policy URI validation"

	cp -R "$evidence" "$broken"
	awk -F '\t' 'BEGIN { OFS = FS } $1 == "rung_c_happy_image" { $4 = "mismatch" } { print }' \
		"$broken/rung-bc-proof-summary.tsv" > "$broken/rung-bc-proof-summary.tsv.tmp"
	mv "$broken/rung-bc-proof-summary.tsv.tmp" "$broken/rung-bc-proof-summary.tsv"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken" > /dev/null 2> "$err"; then
		die "evidence validator accepted a mismatched proof summary"
	fi
	expect_grep "rung-bc proof summary has non-match rows" "$err" "evidence validator proof-summary failure"

	cp -R "$evidence" "$broken_missing_proof"
	awk -F '\t' '$1 != "rung_c_negative_unsigned_image" { print }' \
		"$broken_missing_proof/rung-bc-proof-summary.tsv" > "$broken_missing_proof/rung-bc-proof-summary.tsv.tmp"
	mv "$broken_missing_proof/rung-bc-proof-summary.tsv.tmp" "$broken_missing_proof/rung-bc-proof-summary.tsv"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_missing_proof" > /dev/null 2> "$missing_proof_err"; then
		die "evidence validator accepted a proof summary missing a required row"
	fi
	expect_grep "rung-bc proof summary missing required row: rung_c_negative_unsigned_image" "$missing_proof_err" "evidence validator missing proof-summary row failure"

	cp -R "$evidence" "$broken_key_id"
	jq '.rung_b.key_id = "kbs:///wrong/image-key/rung-b"' "$broken_key_id/rung-bc-images.json" > "$broken_key_id/rung-bc-images.json.tmp"
	mv "$broken_key_id/rung-bc-images.json.tmp" "$broken_key_id/rung-bc-images.json"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_key_id" > /dev/null 2> "$key_id_err"; then
		die "evidence validator accepted a rung-b manifest with the wrong key ID"
	fi
	expect_grep "wrong rung-b key ID" "$key_id_err" "evidence validator rung-b key ID failure"

	cp -R "$evidence" "$broken_mirror"
	rm -f "$broken_mirror/mirror/files/access.log"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_mirror" > /dev/null 2> "$mirror_err"; then
		die "evidence validator accepted missing mirror logs"
	fi
	expect_grep "mirror logs missing or empty" "$mirror_err" "evidence validator mirror-log failure"

	cp -R "$evidence" "$broken_digest"
	sed -i 's/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/' \
		"$broken_digest/mirror/files/access.log"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_digest" > /dev/null 2> "$digest_err"; then
		die "evidence validator accepted a mirror log with the wrong digest"
	fi
	expect_grep "mirror logs missing guest oci-client manifest pull coco/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$digest_err" "evidence validator mirror digest failure"

	cp -R "$evidence" "$broken_guest_pull"
	sed -i '/coco\/rung-b\//s#"oci-client/0.15.0"#"cri-o/1.33.10 os/linux arch/amd64"#' \
		"$broken_guest_pull/mirror/files/access.log"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_guest_pull" > /dev/null 2> "$guest_pull_err"; then
		die "evidence validator accepted a host-only mirror pull for rung-b"
	fi
	expect_grep "rung-b happy image mirror logs missing guest oci-client manifest pull coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$guest_pull_err" "evidence validator guest-pull failure"

	cp -R "$evidence" "$broken_blob_pull"
	sed -i '/coco\/rung-c\/blobs/d' "$broken_blob_pull/mirror/files/access.log"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_blob_pull" > /dev/null 2> "$blob_pull_err"; then
		die "evidence validator accepted a happy image without a guest blob pull"
	fi
	expect_grep "rung-c happy image mirror logs missing guest oci-client blob pull coco/rung-c" "$blob_pull_err" "evidence validator blob-pull failure"

	cp -R "$evidence" "$broken_b_initdata"
	cp "$broken_b_initdata/pods/rung-b-encrypted.initdata.toml" "$broken_b_initdata/pods/negtest-rung-b.initdata.toml"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_b_initdata" > /dev/null 2> "$b_initdata_err"; then
		die "evidence validator accepted an unchanged rung-b negative decoded initdata"
	fi
	expect_grep "rung-b negative decoded initdata matches happy decoded initdata" "$b_initdata_err" "evidence validator rung-b initdata failure"

	cp -R "$evidence" "$broken_c_initdata"
	printf '\n# unexpected policy mutation\n' >> "$broken_c_initdata/pods/negtest-rung-c.initdata.toml"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_c_initdata" > /dev/null 2> "$c_initdata_err"; then
		die "evidence validator accepted a changed rung-c negative decoded initdata"
	fi
	expect_grep "rung-c negative decoded initdata differs from happy decoded initdata" "$c_initdata_err" "evidence validator rung-c initdata failure"

	cp -R "$evidence" "$broken_decoded_initdata"
	sed -i 's#kbs:///default/security-policy/rung-c#kbs:///default/security-policy/test#' \
		"$broken_decoded_initdata/pods/rung-c-signed.initdata.toml"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_decoded_initdata" > /dev/null 2> "$decoded_initdata_err"; then
		die "evidence validator accepted a rung-c decoded initdata policy mismatch"
	fi
	expect_grep "rung-c initdata policy URI missing" "$decoded_initdata_err" "evidence validator decoded initdata policy failure"

	cp -R "$evidence" "$broken_kbs_url"
	sed -i 's#http://kbs.trustee-test.svc:8080#http://wrong-kbs.trustee-test.svc:8080#g' \
		"$broken_kbs_url/pods/rung-b-encrypted.initdata.toml"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_kbs_url" > /dev/null 2> "$kbs_url_err"; then
		die "evidence validator accepted a decoded initdata KBS URL mismatch"
	fi
	expect_grep "rung-b initdata KBS URL missing or incomplete" "$kbs_url_err" "evidence validator decoded initdata KBS URL failure"

	cp -R "$evidence" "$broken_app_log"
	printf 'app started without expected proof marker\n' > "$broken_app_log/pods/rung-b-encrypted.logs.txt"
	jq '
		.status.phase = "Pending" |
		.status.conditions = [
			{
				"type": "Ready",
				"status": "False"
			},
			{
				"type": "ContainersReady",
				"status": "False"
			}
		] |
		.status.containerStatuses[0].ready = false |
		.status.containerStatuses[0].started = false |
		.status.containerStatuses[0].state = {
			"waiting": {
				"reason": "ImagePullBackOff"
			}
		}
	' "$broken_app_log/pods/rung-b-encrypted.json" > "$broken_app_log/pods/rung-b-encrypted.json.tmp"
	mv "$broken_app_log/pods/rung-b-encrypted.json.tmp" "$broken_app_log/pods/rung-b-encrypted.json"
	if bash "$REPO_ROOT/scripts/validate-rung-bc-evidence.sh" "$broken_app_log" > /dev/null 2> "$app_log_err"; then
		die "evidence validator accepted a missing rung-b app log marker"
	fi
	expect_grep "rung-b app start evidence missing" "$app_log_err" "evidence validator app-start failure"
}

write_valid_rung_b_direct_pull_diagnostic() {
	local diag="$1"
	mkdir -p "$diag/mirror"
	cat > "$diag/summary.env" <<'EOF'
timestamp_utc=2026-06-30T07:32:23Z
namespace=default
trustee_namespace=trustee-operator-system
pod_name=rung-b-direct-pull-diag
node=sno-coco-node
rung_b_image=mirror.rig.local:8443/coco/rung-b@sha256:69b8fa1c66919ff9d4412fc6ecd0139aa78883c93fdfc78db0aecd526de0890c
rung_b_key_id=kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c
rung_b_key_resource=default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c
rung_b_policy_uri=kbs:///default/security-policy/test
phase=Pending
host_pull_blocker_seen=1
image_key_request_seen=0
mirror_crio_rung_b_manifest_count=16
mirror_crio_rung_b_blob_count=16
mirror_guest_rung_b_manifest_count=0
mirror_guest_rung_b_blob_count=0
classification=known-host-pull-blocker
EOF
	cat > "$diag/classification.txt" <<'EOF'
REPRODUCED: host-side encrypted-layer pull blocked before guest image-key request.
EOF
	cat > "$diag/context.txt" <<'EOF'
Warning  Failed  kubelet  encrypted layer sha256:346e9... should be decrypted, but we can't modify the manifest: Destination specifies a digest
EOF
	cat > "$diag/trustee.log" <<'EOF'
GET /kbs/v0/resource/default/security-policy/test 200
EOF
	cat > "$diag/mirror/summary.tsv" <<'EOF'
signal	count
mirror_context_available	1
crio_rung_b_manifest	16
crio_rung_b_blob	16
guest_rung_b_manifest	0
guest_rung_b_blob	0
EOF
}

verify_rung_b_direct_pull_diagnostic_validation() {
	local diag="$tmpdir/valid-direct-pull-diagnostic" out="$tmpdir/validate-direct-pull.out"
	local make_out="$tmpdir/validate-direct-pull-make.out"
	local legacy_diag="$tmpdir/legacy-direct-pull-diagnostic" legacy_out="$tmpdir/validate-direct-pull-legacy.out"
	local broken_guest="$tmpdir/broken-direct-pull-guest" guest_err="$tmpdir/validate-direct-pull-guest.err"
	local broken_key="$tmpdir/broken-direct-pull-key" key_err="$tmpdir/validate-direct-pull-key.err"
	write_valid_rung_b_direct_pull_diagnostic "$diag"
	bash "$REPO_ROOT/scripts/validate-rung-b-direct-pull-diagnostic.sh" "$diag" > "$out"
	expect_grep "Rung-b direct-pull diagnostic validation OK." "$out" "valid direct-pull diagnostic validation"
	expect_grep "mirror summary shows CRI-O rung-b blob pulls" "$out" "direct-pull diagnostic CRI-O blob count"
	expect_grep "mirror summary shows no guest rung-b blob pulls" "$out" "direct-pull diagnostic guest blob count"

	make -s validate-rung-b-direct-pull DIAG_DIR="$diag" > "$make_out"
	expect_grep "Rung-b direct-pull diagnostic validation OK." "$make_out" "Makefile direct-pull diagnostic validation"

	cp -R "$diag" "$legacy_diag"
	rm -rf "$legacy_diag/mirror"
	make -s validate-rung-b-direct-pull DIAG_DIR="$legacy_diag" REQUIRE_MIRROR_SUMMARY=0 > "$legacy_out"
	expect_grep "mirror summary not required" "$legacy_out" "Makefile direct-pull legacy diagnostic validation"
	expect_grep "Rung-b direct-pull diagnostic validation OK." "$legacy_out" "Makefile direct-pull legacy diagnostic result"

	cp -R "$diag" "$broken_guest"
	sed -i 's/^guest_rung_b_blob	0$/guest_rung_b_blob	1/' "$broken_guest/mirror/summary.tsv"
	if bash "$REPO_ROOT/scripts/validate-rung-b-direct-pull-diagnostic.sh" "$broken_guest" > /dev/null 2> "$guest_err"; then
		die "direct-pull diagnostic validator accepted a guest rung-b blob pull"
	fi
	expect_grep "guest rung-b blob count is 1, expected 0" "$guest_err" "direct-pull diagnostic guest pull failure"

	cp -R "$diag" "$broken_key"
	sed -i 's/^image_key_request_seen=0$/image_key_request_seen=1/' "$broken_key/summary.env"
	if bash "$REPO_ROOT/scripts/validate-rung-b-direct-pull-diagnostic.sh" "$broken_key" > /dev/null 2> "$key_err"; then
		die "direct-pull diagnostic validator accepted an image-key request"
	fi
	expect_grep "Trustee image-key request signal is 1, expected 0" "$key_err" "direct-pull diagnostic image-key failure"
}

verify_evidence_validation_make_env() {
	local stub="$tmpdir/validate-evidence-stub.sh" out="$tmpdir/validate-evidence-make-env"
	cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARG=%s\n' "${1:-}"
vars=(
	EVIDENCE_DIR
	KBS_URL
	RUNG_B_KEY_ID
	RUNG_B_POLICY_URI
	RUNG_C_POLICY_URI
	RUNG_B_POD
	RUNG_C_POD
	NEG_RUNG_B_POD
	NEG_RUNG_C_POD
	RUNG_B_APP_LOG_MARKER
	RUNG_C_APP_LOG_MARKER
)
for var in "${vars[@]}"; do
	printf '%s=%s\n' "$var" "${!var-}"
done
EOF
	chmod +x "$stub"
	make -s validate-rung-bc-evidence \
		VALIDATE_RUNG_BC_EVIDENCE_SCRIPT="$stub" \
		EVIDENCE_DIR="$tmpdir/evidence-for-validation" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_KEY_ID="kbs:///default/custom-image-key/rung-b" \
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_C_POLICY_URI="kbs:///custom/security-policy/rung-c" \
		RUNG_B_POD="custom-rung-b" \
		RUNG_C_POD="custom-rung-c" \
		NEG_RUNG_B_POD="custom-neg-rung-b" \
		NEG_RUNG_C_POD="custom-neg-rung-c" \
		RUNG_B_APP_LOG_MARKER="custom rung-b proof marker" \
		RUNG_C_APP_LOG_MARKER="custom rung-c proof marker" \
		> "$out"
	expect_grep "ARG=$tmpdir/evidence-for-validation" "$out" "Makefile validate evidence directory argument"
	expect_grep "EVIDENCE_DIR=$tmpdir/evidence-for-validation" "$out" "Makefile validate evidence dir env"
	expect_grep "KBS_URL=http://kbs.trustee-test.svc:8080" "$out" "Makefile validate KBS URL env"
	expect_grep "RUNG_B_KEY_ID=kbs:///default/custom-image-key/rung-b" "$out" "Makefile validate rung-b key ID env"
	expect_grep "RUNG_B_POLICY_URI=kbs:///custom/security-policy/rung-b" "$out" "Makefile validate rung-b policy URI env"
	expect_grep "RUNG_C_POLICY_URI=kbs:///custom/security-policy/rung-c" "$out" "Makefile validate rung-c policy URI env"
	expect_grep "RUNG_B_POD=custom-rung-b" "$out" "Makefile validate rung-b pod override"
	expect_grep "RUNG_C_POD=custom-rung-c" "$out" "Makefile validate rung-c pod override"
	expect_grep "NEG_RUNG_B_POD=custom-neg-rung-b" "$out" "Makefile validate negative rung-b pod override"
	expect_grep "NEG_RUNG_C_POD=custom-neg-rung-c" "$out" "Makefile validate negative rung-c pod override"
	expect_grep "RUNG_B_APP_LOG_MARKER=custom rung-b proof marker" "$out" "Makefile validate rung-b app marker override"
	expect_grep "RUNG_C_APP_LOG_MARKER=custom rung-c proof marker" "$out" "Makefile validate rung-c app marker override"
}

create_prove_stub() {
	local path="$1" name="$2"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'set -euo pipefail\n'
		printf 'PROOF_STUB_NAME=%q\n' "$name"
		cat <<'EOF'
printf '%s\targ=%s\tKEEP_DENIED_PODS=%s\tEVIDENCE_DIR=%s\tRUNG_B_IMAGE=%s\tRUNG_C_IMAGE=%s\tRUNG_C_UNSIGNED_IMAGE=%s\tNS=%s\tTRUSTEE_NS=%s\tKBS_URL=%s\tRUNG_B_KEY_ID=%s\tIMAGE_SECURITY_POLICY_URI=%s\tRUNG_B_POLICY_URI=%s\tRUNG_C_POLICY_URI=%s\tPODS=%s\tRUNG_B_POD=%s\tRUNG_C_POD=%s\tNEG_RUNG_B_POD=%s\tNEG_RUNG_C_POD=%s\tRUNG_B_APP_LOG_MARKER=%s\tRUNG_C_APP_LOG_MARKER=%s\tTRUSTEE_LOG_TAIL=%s\tPOD_LOG_TAIL=%s\tMIRROR_LOG_TAIL=%s\tMIRROR_LOG_FILES=%s\tMIRROR_CONTAINER_NAMES=%s\n' \
	"$PROOF_STUB_NAME" "${1:-}" "${KEEP_DENIED_PODS:-}" "${EVIDENCE_DIR:-}" \
	"${RUNG_B_IMAGE:-}" "${RUNG_C_IMAGE:-}" "${RUNG_C_UNSIGNED_IMAGE:-}" \
	"${NS:-}" "${TRUSTEE_NS:-}" "${KBS_URL:-}" "${RUNG_B_KEY_ID:-}" "${IMAGE_SECURITY_POLICY_URI:-}" \
	"${RUNG_B_POLICY_URI:-}" "${RUNG_C_POLICY_URI:-}" "${PODS:-}" "${RUNG_B_POD:-}" \
	"${RUNG_C_POD:-}" "${NEG_RUNG_B_POD:-}" "${NEG_RUNG_C_POD:-}" "${RUNG_B_APP_LOG_MARKER:-}" \
	"${RUNG_C_APP_LOG_MARKER:-}" "${TRUSTEE_LOG_TAIL:-}" "${POD_LOG_TAIL:-}" \
	"${MIRROR_LOG_TAIL:-}" "${MIRROR_LOG_FILES:-}" "${MIRROR_CONTAINER_NAMES:-}" >> "$CALL_LOG"
EOF
	} > "$path"
	chmod +x "$path"
}

verify_prove_rung_bc_workflow() {
	local dir="$tmpdir/prove-rung-bc" log="$tmpdir/prove-rung-bc-calls.tsv" err="$tmpdir/prove-rung-bc.err" bad_log="$tmpdir/prove-rung-bc-bad-calls.tsv"
	local apply_b apply_c negative collect validate
	mkdir -p "$dir"
	apply_b="$dir/apply-b.sh"
	apply_c="$dir/apply-c.sh"
	negative="$dir/negative-test.sh"
	collect="$dir/collect-evidence.sh"
	validate="$dir/validate-evidence.sh"
	create_prove_stub "$apply_b" apply-b
	create_prove_stub "$apply_c" apply-c
	create_prove_stub "$negative" negative-test
	create_prove_stub "$collect" collect-evidence
	create_prove_stub "$validate" validate-evidence

	CALL_LOG="$log" make -s prove-rung-bc \
		APPLY_RUNG_B_SCRIPT="$apply_b" \
		APPLY_RUNG_C_SCRIPT="$apply_c" \
		NEGATIVE_TEST_SCRIPT="$negative" \
		COLLECT_RUNG_BC_EVIDENCE_SCRIPT="$collect" \
		VALIDATE_RUNG_BC_EVIDENCE_SCRIPT="$validate" \
		NS="trustee-test" \
		WORKLOAD_NS="workload-test" \
		KBS_URL="http://kbs.trustee-test.svc:8080" \
		RUNG_B_KEY_ID="kbs:///default/custom-image-key/rung-b" \
		RUNG_B_POLICY_URI="kbs:///custom/security-policy/rung-b" \
		RUNG_C_POLICY_URI="kbs:///custom/security-policy/rung-c" \
		ARTIFACT_DIR="$tmpdir/artifacts" \
		EVIDENCE_DIR="$tmpdir/proof-evidence" \
		EVIDENCE_PODS="rung-b-encrypted rung-c-signed negtest-rung-b negtest-rung-c" \
		RUNG_B_POD="rung-b-encrypted" \
		RUNG_C_POD="rung-c-signed" \
		NEG_RUNG_B_POD="negtest-rung-b" \
		NEG_RUNG_C_POD="negtest-rung-c" \
		RUNG_B_APP_LOG_MARKER="custom rung-b proof marker" \
		RUNG_C_APP_LOG_MARKER="custom rung-c proof marker" \
		TRUSTEE_LOG_TAIL="111" \
		POD_LOG_TAIL="222" \
		MIRROR_LOG_TAIL="333" \
		MIRROR_LOG_FILES="/var/log/custom-mirror.log /srv/mirror/access.log" \
		MIRROR_CONTAINER_NAMES="quay-app custom-registry" \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
		RUNG_C_IMAGE="mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		> /dev/null

	expect_grep "apply-b	arg=	KEEP_DENIED_PODS=	EVIDENCE_DIR=$tmpdir/proof-evidence" "$log" "prove-rung-bc apply-b step"
	expect_grep "apply-c	arg=	KEEP_DENIED_PODS=	EVIDENCE_DIR=$tmpdir/proof-evidence" "$log" "prove-rung-bc apply-c step"
	expect_grep $'negative-test\targ=rung-b\tKEEP_DENIED_PODS=1' "$log" "prove-rung-bc rung-b negative step"
	expect_grep $'negative-test\targ=rung-c\tKEEP_DENIED_PODS=1' "$log" "prove-rung-bc rung-c negative step"
	expect_grep "collect-evidence	arg=	KEEP_DENIED_PODS=	EVIDENCE_DIR=$tmpdir/proof-evidence" "$log" "prove-rung-bc collect evidence dir"
	expect_grep "validate-evidence	arg=$tmpdir/proof-evidence	KEEP_DENIED_PODS=	EVIDENCE_DIR=$tmpdir/proof-evidence" "$log" "prove-rung-bc validate evidence dir"
	expect_grep "NS=workload-test" "$log" "prove-rung-bc workload namespace"
	expect_grep "TRUSTEE_NS=trustee-test" "$log" "prove-rung-bc Trustee namespace"
	expect_grep "KBS_URL=http://kbs.trustee-test.svc:8080" "$log" "prove-rung-bc KBS URL"
	expect_grep "RUNG_B_KEY_ID=kbs:///default/custom-image-key/rung-b" "$log" "prove-rung-bc rung-b key ID"
	expect_grep "IMAGE_SECURITY_POLICY_URI=kbs:///custom/security-policy/rung-b" "$log" "prove-rung-bc apply rung-b policy URI"
	expect_grep "IMAGE_SECURITY_POLICY_URI=kbs:///custom/security-policy/rung-c" "$log" "prove-rung-bc apply rung-c policy URI"
	expect_grep "RUNG_B_POLICY_URI=kbs:///custom/security-policy/rung-b" "$log" "prove-rung-bc rung-b policy URI"
	expect_grep "RUNG_C_POLICY_URI=kbs:///custom/security-policy/rung-c" "$log" "prove-rung-bc rung-c policy URI"
	expect_grep "PODS=rung-b-encrypted rung-c-signed negtest-rung-b negtest-rung-c" "$log" "prove-rung-bc evidence pod list"
	expect_grep "collect-evidence	arg=	KEEP_DENIED_PODS=	EVIDENCE_DIR=$tmpdir/proof-evidence" "$log" "prove-rung-bc collect evidence step"
	expect_grep "TRUSTEE_LOG_TAIL=111" "$log" "prove-rung-bc collect Trustee log tail"
	expect_grep "POD_LOG_TAIL=222" "$log" "prove-rung-bc collect pod log tail"
	expect_grep "MIRROR_LOG_TAIL=333" "$log" "prove-rung-bc collect mirror log tail"
	expect_grep "MIRROR_LOG_FILES=/var/log/custom-mirror.log /srv/mirror/access.log" "$log" "prove-rung-bc collect mirror log files"
	expect_grep "MIRROR_CONTAINER_NAMES=quay-app custom-registry" "$log" "prove-rung-bc collect mirror containers"
	expect_grep "validate-evidence	arg=$tmpdir/proof-evidence" "$log" "prove-rung-bc validate evidence step"
	expect_grep "RUNG_B_APP_LOG_MARKER=custom rung-b proof marker" "$log" "prove-rung-bc validate rung-b app marker"
	expect_grep "RUNG_C_APP_LOG_MARKER=custom rung-c proof marker" "$log" "prove-rung-bc validate rung-c app marker"

	if CALL_LOG="$bad_log" make -s prove-rung-bc \
		APPLY_RUNG_B_SCRIPT="$apply_b" \
		APPLY_RUNG_C_SCRIPT="$apply_c" \
		NEGATIVE_TEST_SCRIPT="$negative" \
		COLLECT_RUNG_BC_EVIDENCE_SCRIPT="$collect" \
		VALIDATE_RUNG_BC_EVIDENCE_SCRIPT="$validate" \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b:encrypted" \
		RUNG_C_IMAGE="mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
		> /dev/null 2> "$err"; then
		die "prove-rung-bc accepted a tagged rung-b image"
	fi
	expect_grep "RUNG_B_IMAGE must be a sha256 digest ref" "$err" "prove-rung-bc digest-ref guard"
	[[ ! -s "$bad_log" ]] || die "prove-rung-bc called child scripts after digest-ref guard failed"
}

verify_prove_rung_bc_loads_artifact_env() {
	local dir="$tmpdir/prove-rung-bc-env" artifacts="$tmpdir/prove-rung-bc-artifacts" log="$tmpdir/prove-rung-bc-env-calls.tsv"
	local apply_b apply_c negative collect validate
	mkdir -p "$dir" "$artifacts"
	apply_b="$dir/apply-b.sh"
	apply_c="$dir/apply-c.sh"
	negative="$dir/negative-test.sh"
	collect="$dir/collect-evidence.sh"
	validate="$dir/validate-evidence.sh"
	create_prove_stub "$apply_b" apply-b-env
	create_prove_stub "$apply_c" apply-c-env
	create_prove_stub "$negative" negative-test-env
	create_prove_stub "$collect" collect-evidence-env
	create_prove_stub "$validate" validate-evidence-env

cat > "$artifacts/rung-bc.env" <<'EOF'
export RUNG_B_IMAGE=mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export RUNG_B_KEY_ID=kbs:///default/image-key/rung-b
export RUNG_B_KEY_FILE=/tmp/rung-b-image.key
export RUNG_C_IMAGE=mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export RUNG_C_UNSIGNED_IMAGE=mirror.test.local:5000/coco/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
export RUNG_C_COSIGN_PUB=/tmp/cosign.pub
EOF

	CALL_LOG="$log" make -s prove-rung-bc \
		APPLY_RUNG_B_SCRIPT="$apply_b" \
		APPLY_RUNG_C_SCRIPT="$apply_c" \
		NEGATIVE_TEST_SCRIPT="$negative" \
		COLLECT_RUNG_BC_EVIDENCE_SCRIPT="$collect" \
		VALIDATE_RUNG_BC_EVIDENCE_SCRIPT="$validate" \
		ARTIFACT_DIR="$artifacts" \
		RUNG_B_IMAGE="mirror.test.local:5000/coco/rung-b:encrypted" \
		RUNG_C_IMAGE="mirror.test.local:5000/coco/rung-c:signed" \
		RUNG_C_UNSIGNED_IMAGE="mirror.test.local:5000/coco/rung-c:unsigned" \
		> /dev/null

	expect_grep "apply-b-env	arg=	KEEP_DENIED_PODS=	EVIDENCE_DIR=$artifacts/evidence-rung-bc-proof-" "$log" "prove-rung-bc artifact env apply-b step"
	expect_grep "RUNG_B_IMAGE=mirror.test.local:5000/coco/rung-b@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$log" "prove-rung-bc loaded rung-b image from env"
	expect_grep "RUNG_C_IMAGE=mirror.test.local:5000/coco/rung-c@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$log" "prove-rung-bc loaded rung-c image from env"
	expect_grep "RUNG_C_UNSIGNED_IMAGE=mirror.test.local:5000/coco/rung-c-unsigned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$log" "prove-rung-bc loaded unsigned image from env"
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
verify_deterministic_initdata_encoding
verify_build_manifest_fingerprints
verify_apply_requires_digest_refs
verify_rung_b_key_size_guard
verify_manifest_env_emit
verify_gen_rvps_veritas_local_command
verify_rung_b_measurement_policy_render
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
verify_rung_b_direct_pull_diagnostic_validation
verify_evidence_validation_make_env
verify_prove_rung_bc_workflow
verify_prove_rung_bc_loads_artifact_env

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
	RUNG_B_KEY_ID="kbs:///default/image-kek/380af3e3-69f8-4985-9196-e9261a19072c" \
	RUNG_C_COSIGN_PUB="$tmpdir/cosign.pub" \
	RENDER_KBSCONFIG_ONLY=1 \
	bash "$REPO_ROOT/scripts/apply-trustee.sh" > "$tmpdir/kbsconfig-rung-bc.yaml"
expect_grep "mountPath: /opt/confidential-containers/attestation-service/kds-store/vcek/$hwid" "$tmpdir/kbsconfig-rung-bc.yaml" "rendered HWID mount path"
grep -Eq '^[[:space:]]+- image-kek[[:space:]]*$' "$tmpdir/kbsconfig-rung-bc.yaml" || die "rendered KbsConfig missing custom image-kek"
grep -Eq '^[[:space:]]+- sig-public-key[[:space:]]*$' "$tmpdir/kbsconfig-rung-bc.yaml" || die "rendered KbsConfig missing sig-public-key"

echo "rung b/c render checks OK"
