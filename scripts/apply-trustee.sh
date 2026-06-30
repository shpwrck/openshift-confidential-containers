#!/usr/bin/env bash
# Apply the rig Trustee with the live SNP HWID rendered into KbsConfig.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-trustee-operator-system}"
VCEK_BUNDLE="${VCEK_BUNDLE:-${REPO_ROOT}/vcek-bundle}"
HWID="${HWID:-}"
HWIDS="${HWIDS:-}"
RUNG_B_KEY_FILE="${RUNG_B_KEY_FILE:-}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-kbs:///default/image-key/rung-b}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-}"
RUNG_C_COSIGN_PUB="${RUNG_C_COSIGN_PUB:-}"
RUNG_C_POLICY_FILE="${RUNG_C_POLICY_FILE:-}"
RUNG_C_POLICY_IMAGE_PREFIX="${RUNG_C_POLICY_IMAGE_PREFIX:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

tmpdir=""
vcek_hwids=()
extra_secret_resources=()
RUNG_B_KEY_SECRET=""

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
	local path="$1" size
	size="$(file_size_bytes "$path")"
	[[ "$size" == "32" ]] || die "rung-b image key must be exactly 32 bytes: $path (${size} bytes)"
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

cleanup() {
	[[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
}
trap cleanup EXIT

load_vcek_bundle() {
	local raw hwid der
	raw="${HWIDS:-$HWID}"
	raw="${raw//,/ }"
	if [[ -n "$raw" ]]; then
		for hwid in $raw; do
			hwid="$(printf '%s' "$hwid" | tr 'A-F' 'a-f')"
			[[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "HWID must be 128 lowercase hex chars: $hwid"
			[[ -s "$VCEK_BUNDLE/$hwid/vcek.der" ]] || die "missing VCEK file: $VCEK_BUNDLE/$hwid/vcek.der"
			vcek_hwids+=("$hwid")
		done
	else
		mapfile -t ders < <(find "$VCEK_BUNDLE" -mindepth 2 -maxdepth 2 -type f -name vcek.der 2>/dev/null | sort)
		[[ "${#ders[@]}" -gt 0 ]] || die "no VCEK files found in $VCEK_BUNDLE; expected $VCEK_BUNDLE/<hwid>/vcek.der"
		for der in "${ders[@]}"; do
			hwid="$(basename "$(dirname "$der")" | tr 'A-F' 'a-f')"
			[[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "invalid HWID directory name for $der: $hwid"
			vcek_hwids+=("$hwid")
		done
	fi
	echo "Using ${#vcek_hwids[@]} VCEK bundle entr$( [[ ${#vcek_hwids[@]} -eq 1 ]] && echo y || echo ies )" >&2
}

load_extra_secret_resources() {
	local parsed
	extra_secret_resources=()
	if [[ -n "$RUNG_B_KEY_FILE" ]]; then
		[[ -s "$RUNG_B_KEY_FILE" ]] || die "missing rung-b key file: $RUNG_B_KEY_FILE"
		require_rung_b_key_size "$RUNG_B_KEY_FILE"
		parsed="$(kbs_uri_default_secret_key "$RUNG_B_KEY_ID")"
		RUNG_B_KEY_SECRET="${parsed%%	*}"
		extra_secret_resources+=("$RUNG_B_KEY_SECRET")
	fi
	if [[ -n "$RUNG_C_COSIGN_PUB" ]]; then
		[[ -s "$RUNG_C_COSIGN_PUB" ]] || die "missing rung-c cosign public key: $RUNG_C_COSIGN_PUB"
		extra_secret_resources+=(sig-public-key)
	fi
	if [[ -n "$RUNG_C_POLICY_FILE" ]]; then
		[[ -s "$RUNG_C_POLICY_FILE" ]] || die "missing rung-c policy file: $RUNG_C_POLICY_FILE"
	fi
}

render_kbsconfig() {
	local out="$1" block="" extra_block="" i hwid resource
	for i in "${!vcek_hwids[@]}"; do
		hwid="${vcek_hwids[$i]}"
		block+="      - secretName: vcek-snp-${i}"$'\n'
		block+="        mountPath: /opt/confidential-containers/attestation-service/kds-store/vcek/${hwid}"$'\n'
	done
	for resource in "${extra_secret_resources[@]}"; do
		extra_block+="    - ${resource}"$'\n'
	done
	awk -v block="$block" -v extra_block="$extra_block" '
		/^[[:space:]]+- secretName: vcek-snp-0[[:space:]]*($|#)/ {
			printf "%s", block
			skip = 1
			next
		}
		skip && /^[[:space:]]*mountPath:/ {
			skip = 0
			next
		}
		skip { next }
		{
			print
			if ($0 ~ /^[[:space:]]+- registry-configuration[[:space:]]*($|#)/ && extra_block != "") {
				printf "%s", extra_block
			}
		}
	' "$REPO_ROOT/gitops/base/trustee/kbsconfig.yaml" > "$out"
}

wait_until() {
	local label="$1"
	shift
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	while (( SECONDS < deadline )); do
		if "$@"; then
			echo "PASS: $label"
			return 0
		fi
		echo "Waiting ${SLEEP_SECONDS}s for ${label}..."
		sleep "$SLEEP_SECONDS"
	done
	echo "ERROR: timed out waiting for ${label}" >&2
	return 1
}

trustee_deployment_exists() {
	oc -n "$NS" get deployment trustee-deployment >/dev/null 2>&1
}

trustee_rollout_available() {
	oc -n "$NS" rollout status deployment/trustee-deployment --timeout=10s >/dev/null 2>&1
}

cd "$REPO_ROOT"
load_vcek_bundle
load_extra_secret_resources
tmpdir="$(mktemp -d)"
render_kbsconfig "$tmpdir/kbsconfig.yaml"

if [[ "${RENDER_KBSCONFIG_ONLY:-}" == "1" ]]; then
	cat "$tmpdir/kbsconfig.yaml"
	exit 0
fi

need oc
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

NS="$NS" VCEK_BUNDLE="$VCEK_BUNDLE" HWIDS="${vcek_hwids[*]}" \
	RUNG_B_KEY_FILE="$RUNG_B_KEY_FILE" \
	RUNG_B_KEY_ID="$RUNG_B_KEY_ID" \
	RUNG_C_IMAGE="$RUNG_C_IMAGE" \
	RUNG_C_COSIGN_PUB="$RUNG_C_COSIGN_PUB" \
	RUNG_C_POLICY_FILE="$RUNG_C_POLICY_FILE" \
	RUNG_C_POLICY_IMAGE_PREFIX="$RUNG_C_POLICY_IMAGE_PREFIX" \
	bash "$REPO_ROOT/scripts/seed-trustee-secrets.sh"

oc apply -f gitops/base/trustee/issuers.yaml
oc apply -f gitops/base/trustee/kbs-configmaps.yaml
oc apply -f "$tmpdir/kbsconfig.yaml"

wait_until "Trustee deployment exists" trustee_deployment_exists
wait_until "Trustee deployment available" trustee_rollout_available

echo "Trustee KBS install OK"
echo "KBS URL for in-cluster CoCo workloads: http://kbs-service.${NS}.svc:8080"
