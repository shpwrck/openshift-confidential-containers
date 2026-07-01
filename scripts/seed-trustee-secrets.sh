#!/usr/bin/env bash
# Idempotently create the rig Trustee secrets from bastion-local files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/compat.sh
source "${REPO_ROOT}/scripts/lib/compat.sh"
NS="${NS:-trustee-operator-system}"
VCEK_BUNDLE="${VCEK_BUNDLE:-${REPO_ROOT}/vcek-bundle}"
HWID="${HWID:-}"
HWIDS="${HWIDS:-}"
MIRROR_REGISTRY="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
MIRROR_PULL_SECRET="${MIRROR_PULL_SECRET:-}"   # dockerconfigjson pull secret (the customer model): when set, the
                                               # mirror credential is read FROM it and MIRROR_USERNAME/PASSWORD are ignored.
MIRROR_USERNAME="${MIRROR_USERNAME:-init}"
MIRROR_PASSWORD_FILE="${MIRROR_PASSWORD_FILE:-/opt/mirror/mirror-admin-password}"
MIRROR_CA="${MIRROR_CA:-/opt/mirror/ca/rootCA.pem}"
KBS_PUB="${KBS_PUB:-${HOME}/kbs.pub}"
ATTESTATION_CERT="${ATTESTATION_CERT:-$MIRROR_CA}"
SAMPLE_SECRET="${SAMPLE_SECRET:-rung-a-demo-value}"
RUNG_ENCRYPTED_KEY_FILE="${RUNG_ENCRYPTED_KEY_FILE:-}"
RUNG_ENCRYPTED_KEY_ID="${RUNG_ENCRYPTED_KEY_ID:-kbs:///default/image-key/rung-encrypted}"
RUNG_SIGNED_COSIGN_PUB="${RUNG_SIGNED_COSIGN_PUB:-}"
RUNG_SIGNED_POLICY_FILE="${RUNG_SIGNED_POLICY_FILE:-}"
RUNG_SIGNED_IMAGE="${RUNG_SIGNED_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b:signed}"
RUNG_SIGNED_POLICY_IMAGE_PREFIX="${RUNG_SIGNED_POLICY_IMAGE_PREFIX:-}"

tmpdir=""
vcek_hwids=()
vcek_ders=()
RUNG_ENCRYPTED_KEY_SECRET=""
RUNG_ENCRYPTED_KEY_NAME=""

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

require_rung_encrypted_key_size() {
	local path="$1" size
	size="$(file_size_bytes "$path")"
	[[ "$size" == "32" ]] || die "rung-encrypted image key must be exactly 32 bytes: $path (${size} bytes)"
}

kbs_uri_default_secret_key() {
	local uri="$1" path repo secret key extra
	[[ "$uri" == kbs:///* ]] || die "KBS URI must start with kbs:///: $uri"
	path="${uri#kbs:///}"
	IFS=/ read -r repo secret key extra <<<"$path"
	[[ "$repo" == "default" ]] || die "only default KBS repository is supported for Secret seeding: $uri"
	[[ -n "$secret" && -n "$key" && -z "${extra:-}" ]] || die "KBS URI must be kbs:///default/<secret>/<key>: $uri"
	[[ "$secret" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "KBS Secret resource name is not a valid Kubernetes Secret name: $secret"
	[[ "$key" =~ ^[-._a-zA-Z0-9]+$ ]] || die "KBS Secret key is not a valid Kubernetes Secret key: $key"
	printf '%s\t%s\n' "$secret" "$key"
}

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
	if [[ -n "$tmpdir" ]]; then
		rm -rf "$tmpdir"
	fi
}
trap cleanup EXIT

read_file() {
	local path="$1"
	if [[ -r "$path" ]]; then
		cat "$path"
	elif command -v sudo >/dev/null && sudo -n test -r "$path" 2>/dev/null; then
		sudo -n cat "$path"
	else
		die "cannot read $path"
	fi
}

stage_readable_file() {
	local path="$1" out="$2"
	read_file "$path" > "$out"
}

image_repo_ref() {
	local image="$1" base last_segment
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
	printf '%s\n' "$base"
}

render_default_rung_signed_policy() {
	local image_prefix="$1"
	jq -n --arg image_prefix "$image_prefix" --arg mirror_registry "$MIRROR_REGISTRY" '{
		default: [{type: "reject"}],
		transports: {
			docker: {
				($image_prefix): [
					{
						type: "sigstoreSigned",
						keyPath: "kbs:///default/sig-public-key/rung-signed"
					}
				],
				($mirror_registry + "/openshift/release"): [
					{type: "insecureAcceptAnything"}
				],
				($mirror_registry + "/openshift/release-images"): [
					{type: "insecureAcceptAnything"}
				],
				($mirror_registry + "/ubi9"): [
					{type: "insecureAcceptAnything"}
				]
			}
		}
	}'
}

load_vcek_bundle() {
	local raw hwid der
	raw="${HWIDS:-$HWID}"
	raw="${raw//,/ }"
	if [[ -n "$raw" ]]; then
		for hwid in $raw; do
			hwid="$(printf '%s' "$hwid" | tr 'A-F' 'a-f')"
			[[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "HWID must be 128 lowercase hex chars: $hwid"
			der="$VCEK_BUNDLE/$hwid/vcek.der"
			[[ -s "$der" ]] || die "missing VCEK file: $der"
			vcek_hwids+=("$hwid")
			vcek_ders+=("$der")
		done
	else
		ders=()
		while IFS= read -r der_line; do ders+=("$der_line"); done < <(find "$VCEK_BUNDLE" -mindepth 2 -maxdepth 2 -type f -name vcek.der 2>/dev/null | sort)
		[[ "${#ders[@]}" -gt 0 ]] || die "no VCEK files found in $VCEK_BUNDLE; expected $VCEK_BUNDLE/<hwid>/vcek.der"
		for der in "${ders[@]}"; do
			hwid="$(basename "$(dirname "$der")" | tr 'A-F' 'a-f')"
			[[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "invalid HWID directory name for $der: $hwid"
			vcek_hwids+=("$hwid")
			vcek_ders+=("$der")
		done
	fi
}

apply_secret() {
	oc -n "$NS" apply -f -
}

if [[ -z "$RUNG_SIGNED_POLICY_IMAGE_PREFIX" ]]; then
	RUNG_SIGNED_POLICY_IMAGE_PREFIX="$(image_repo_ref "$RUNG_SIGNED_IMAGE")"
fi

if [[ "${1:-}" == "render-rung-signed-policy" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 render-rung-signed-policy"
	need jq
	render_default_rung_signed_policy "$RUNG_SIGNED_POLICY_IMAGE_PREFIX"
	exit 0
fi

if [[ -n "$RUNG_ENCRYPTED_KEY_FILE" ]]; then
	parsed="$(kbs_uri_default_secret_key "$RUNG_ENCRYPTED_KEY_ID")"
	RUNG_ENCRYPTED_KEY_SECRET="${parsed%%	*}"
	RUNG_ENCRYPTED_KEY_NAME="${parsed#*	}"
	require_rung_encrypted_key_size "$RUNG_ENCRYPTED_KEY_FILE"
fi

need oc
need jq
need base64
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

tmpdir="$(mktemp -d)"
load_vcek_bundle
# Mirror credential for the Trustee `credential`/`regcred` secrets. Customer model: read the mirror
# auth straight out of a single pull secret (dockerconfigjson) — no mirror admin password needed.
# Fall back to the rig's mirror admin user + password file when MIRROR_PULL_SECRET is unset.
if [[ -n "$MIRROR_PULL_SECRET" ]]; then
	# Accept the mirror entry only if it carries a USABLE credential (auth, identitytoken, or
	# username+password) — a present-but-empty {} would otherwise seed a credential that fails opaquely
	# at guest pull time instead of loudly here.
	mirror_auth_entry="$(read_file "$MIRROR_PULL_SECRET" | jq -c --arg r "$MIRROR_REGISTRY" '
		.auths[$r] as $e
		| if ($e.auth // "") != "" or ($e.identitytoken // "") != "" or (($e.username // "") != "" and ($e.password // "") != "")
		  then $e else empty end')"
	[[ -n "$mirror_auth_entry" ]] || die "pull secret ${MIRROR_PULL_SECRET} has no usable auth for ${MIRROR_REGISTRY} (need .auths[\"${MIRROR_REGISTRY}\"] with auth, identitytoken, or username+password)"
	docker_auth_json="$(jq -nc --arg r "$MIRROR_REGISTRY" --argjson e "$mirror_auth_entry" '{auths:{($r):$e}}')"
else
	mirror_password="$(read_file "$MIRROR_PASSWORD_FILE" | tr -d '\n')"
	auth="$(printf '%s' "${MIRROR_USERNAME}:${mirror_password}" | b64_oneline)"
	docker_auth_json="$(jq -nc --arg registry "$MIRROR_REGISTRY" --arg auth "$auth" '{auths:{($registry):{auth:$auth}}}')"
fi

stage_readable_file "$KBS_PUB" "$tmpdir/kbs.pub"
stage_readable_file "$ATTESTATION_CERT" "$tmpdir/attestation.crt"
if [[ -n "$RUNG_ENCRYPTED_KEY_FILE" ]]; then
	stage_readable_file "$RUNG_ENCRYPTED_KEY_FILE" "$tmpdir/rung-encrypted-image.key"
fi
if [[ -n "$RUNG_SIGNED_COSIGN_PUB" ]]; then
	stage_readable_file "$RUNG_SIGNED_COSIGN_PUB" "$tmpdir/cosign.pub"
fi

printf '%s' "$docker_auth_json" > "$tmpdir/credential.json"
printf '%s' "$docker_auth_json" > "$tmpdir/regcred.json"
printf '%s' "$SAMPLE_SECRET" > "$tmpdir/sample"
printf '%s' '{"status":"success"}' > "$tmpdir/attestation-status"
cat > "$tmpdir/security-policy.json" <<EOF
{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"${MIRROR_REGISTRY}":[{"type":"insecureAcceptAnything"}]}}}
EOF
if [[ -n "$RUNG_SIGNED_POLICY_FILE" ]]; then
	stage_readable_file "$RUNG_SIGNED_POLICY_FILE" "$tmpdir/security-policy-rung-signed.json"
elif [[ -n "$RUNG_SIGNED_COSIGN_PUB" ]]; then
	render_default_rung_signed_policy "$RUNG_SIGNED_POLICY_IMAGE_PREFIX" > "$tmpdir/security-policy-rung-signed.json"
fi
cat > "$tmpdir/registries.conf" <<EOF
[[registry]]
prefix = "registry.access.redhat.com/ubi9"
[[registry.mirror]]
location = "${MIRROR_REGISTRY}/ubi9"

[[registry]]
prefix = "quay.io/openshift-release-dev/ocp-v4.0-art-dev"
[[registry.mirror]]
location = "${MIRROR_REGISTRY}/openshift/release"

[[registry]]
prefix = "quay.io/openshift-release-dev/ocp-release"
[[registry.mirror]]
location = "${MIRROR_REGISTRY}/openshift/release-images"
EOF

oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -

oc -n "$NS" create secret generic kbs-auth-public-key \
	--from-file=publicKey="$tmpdir/kbs.pub" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic attestation-cert \
	--from-file=attestation.crt="$tmpdir/attestation.crt" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic regcred \
	--from-file=config="$tmpdir/regcred.json" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic credential \
	--from-file=test="$tmpdir/credential.json" \
	--dry-run=client -o yaml | apply_secret
if [[ -s "$tmpdir/security-policy-rung-signed.json" ]]; then
	oc -n "$NS" create secret generic security-policy \
		--from-file=test="$tmpdir/security-policy.json" \
		--from-file=rung-signed="$tmpdir/security-policy-rung-signed.json" \
		--dry-run=client -o yaml | apply_secret
else
	oc -n "$NS" create secret generic security-policy \
		--from-file=test="$tmpdir/security-policy.json" \
		--dry-run=client -o yaml | apply_secret
fi
oc -n "$NS" create secret generic registry-configuration \
	--from-file=test="$tmpdir/registries.conf" \
	--dry-run=client -o yaml | apply_secret
if [[ -s "$tmpdir/rung-encrypted-image.key" ]]; then
	oc -n "$NS" create secret generic "$RUNG_ENCRYPTED_KEY_SECRET" \
		--from-file="${RUNG_ENCRYPTED_KEY_NAME}=$tmpdir/rung-encrypted-image.key" \
		--dry-run=client -o yaml | apply_secret
fi
if [[ -s "$tmpdir/cosign.pub" ]]; then
	oc -n "$NS" create secret generic sig-public-key \
		--from-file=rung-signed="$tmpdir/cosign.pub" \
		--dry-run=client -o yaml | apply_secret
fi
oc -n "$NS" create secret generic attestation-status \
	--from-file=status="$tmpdir/attestation-status" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic sample \
	--from-file=secret="$tmpdir/sample" \
	--dry-run=client -o yaml | apply_secret
# Stable, collision-free VCEK secret name — readable hwid prefix + hash of the FULL hwid. MUST match
# collect-vcek.sh and apply-trustee.sh render_kbsconfig. A positional index renumbers/remaps KbsConfig
# entries when the chip set changes; this hwid-derived name binds the secret to its chip, and hashing
# the full CHIP_ID keeps two sockets distinct even if their CHIP_IDs share a leading prefix. The full
# hwid stays in the mountPath.
vcek_secret_name() { printf 'vcek-snp-%s-%s\n' "${1:0:16}" "$(printf '%s' "$1" | sha256_stdin | cut -c1-16)"; }
for i in "${!vcek_hwids[@]}"; do
	vcek_name="$(vcek_secret_name "${vcek_hwids[$i]}")"
	oc -n "$NS" create secret generic "$vcek_name" \
		--from-file=vcek.der="${vcek_ders[$i]}" \
		--dry-run=client -o yaml | apply_secret
	echo "VCEK ${vcek_name}: ${vcek_hwids[$i]}"
done

echo "Trustee secrets seeded in $NS"
echo "VCEK_COUNT=${#vcek_hwids[@]}"
[[ -s "$tmpdir/rung-encrypted-image.key" ]] && echo "RUNG_ENCRYPTED_KEY_RESOURCE=${RUNG_ENCRYPTED_KEY_SECRET}/${RUNG_ENCRYPTED_KEY_NAME}"
[[ -s "$tmpdir/cosign.pub" ]] && echo "RUNG_SIGNED_PUBLIC_KEY_RESOURCE=sig-public-key/rung-signed"
[[ -s "$tmpdir/security-policy-rung-signed.json" ]] && echo "RUNG_SIGNED_POLICY_RESOURCE=security-policy/rung-signed"

# The optional `[[ -s ... ]] && echo` summary lines above are false in the plain (no signed
# or encrypted image) case, which would otherwise leave this script's exit status at 1 and abort the caller
# (apply-trustee.sh runs under `set -e`). Force success.
exit 0
