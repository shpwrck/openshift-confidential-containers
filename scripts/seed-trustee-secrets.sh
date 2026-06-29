#!/usr/bin/env bash
# Idempotently create the rig Trustee secrets from bastion-local files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-trustee-operator-system}"
VCEK_BUNDLE="${VCEK_BUNDLE:-${REPO_ROOT}/vcek-bundle}"
HWID="${HWID:-}"
HWIDS="${HWIDS:-}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.rig.local:8443}"
MIRROR_USERNAME="${MIRROR_USERNAME:-init}"
MIRROR_PASSWORD_FILE="${MIRROR_PASSWORD_FILE:-/opt/mirror/mirror-admin-password}"
MIRROR_CA="${MIRROR_CA:-/opt/mirror/ca/rootCA.pem}"
KBS_PUB="${KBS_PUB:-${HOME}/kbs.pub}"
ATTESTATION_CERT="${ATTESTATION_CERT:-$MIRROR_CA}"
SAMPLE_SECRET="${SAMPLE_SECRET:-rung-a-demo-value}"

tmpdir=""
vcek_hwids=()
vcek_ders=()

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

cleanup() {
	[[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
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
		mapfile -t ders < <(find "$VCEK_BUNDLE" -mindepth 2 -maxdepth 2 -type f -name vcek.der 2>/dev/null | sort)
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

need oc
need jq
need base64
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

tmpdir="$(mktemp -d)"
load_vcek_bundle
mirror_password="$(read_file "$MIRROR_PASSWORD_FILE" | tr -d '\n')"
auth="$(printf '%s' "${MIRROR_USERNAME}:${mirror_password}" | base64 -w0)"
docker_auth_json="$(jq -nc --arg registry "$MIRROR_REGISTRY" --arg auth "$auth" '{auths:{($registry):{auth:$auth}}}')"

stage_readable_file "$KBS_PUB" "$tmpdir/kbs.pub"
stage_readable_file "$ATTESTATION_CERT" "$tmpdir/attestation.crt"

printf '%s' "$docker_auth_json" > "$tmpdir/credential.json"
printf '%s' "$docker_auth_json" > "$tmpdir/regcred.json"
printf '%s' "$SAMPLE_SECRET" > "$tmpdir/sample"
printf '%s' '{"status":"success"}' > "$tmpdir/attestation-status"
cat > "$tmpdir/security-policy.json" <<EOF
{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"${MIRROR_REGISTRY}":[{"type":"insecureAcceptAnything"}]}}}
EOF
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
oc -n "$NS" create secret generic security-policy \
	--from-file=test="$tmpdir/security-policy.json" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic registry-configuration \
	--from-file=test="$tmpdir/registries.conf" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic attestation-status \
	--from-file=status="$tmpdir/attestation-status" \
	--dry-run=client -o yaml | apply_secret
oc -n "$NS" create secret generic sample \
	--from-file=secret="$tmpdir/sample" \
	--dry-run=client -o yaml | apply_secret
for i in "${!vcek_hwids[@]}"; do
	oc -n "$NS" create secret generic "vcek-snp-${i}" \
		--from-file=vcek.der="${vcek_ders[$i]}" \
		--dry-run=client -o yaml | apply_secret
	echo "VCEK vcek-snp-${i}: ${vcek_hwids[$i]}"
done

echo "Trustee secrets seeded in $NS"
echo "VCEK_COUNT=${#vcek_hwids[@]}"
