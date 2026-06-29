#!/usr/bin/env bash
# Apply the rig Trustee with the live SNP HWID rendered into KbsConfig.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-trustee-operator-system}"
VCEK_BUNDLE="${VCEK_BUNDLE:-${REPO_ROOT}/vcek-bundle}"
HWID="${HWID:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

tmpdir=""

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

find_hwid() {
	local hwid="$HWID"
	if [[ -z "$hwid" ]]; then
		mapfile -t vceks < <(find "$VCEK_BUNDLE" -mindepth 2 -maxdepth 2 -type f -name vcek.der 2>/dev/null | sort)
		[[ "${#vceks[@]}" -eq 1 ]] || die "set HWID=<lowercase-hwid> (found ${#vceks[@]} VCEK files in $VCEK_BUNDLE)"
		hwid="$(basename "$(dirname "${vceks[0]}")")"
	fi
	hwid="$(printf '%s' "$hwid" | tr 'A-F' 'a-f')"
	[[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "HWID must be 128 lowercase hex chars: $hwid"
	printf '%s\n' "$hwid"
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

need oc
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

cd "$REPO_ROOT"
hwid="$(find_hwid)"
tmpdir="$(mktemp -d)"

NS="$NS" VCEK_BUNDLE="$VCEK_BUNDLE" HWID="$hwid" bash "$REPO_ROOT/scripts/seed-trustee-secrets.sh"

sed "s/<HWID-LOWERCASE-128-HEX>/${hwid}/g" \
	"$REPO_ROOT/gitops/base/trustee/kbsconfig.yaml" > "$tmpdir/kbsconfig.yaml"

oc apply -f gitops/base/trustee/issuers.yaml
oc apply -f gitops/base/trustee/kbs-configmaps.yaml
oc apply -f "$tmpdir/kbsconfig.yaml"

wait_until "Trustee deployment exists" trustee_deployment_exists
wait_until "Trustee deployment available" trustee_rollout_available

echo "Trustee KBS install OK"
echo "KBS URL for in-cluster CoCo workloads: http://kbs-service.${NS}.svc:8080"
