#!/usr/bin/env bash
# Guarded repair for the known SNO baseline drift where MCD reports:
#   content mismatch for file "/etc/kubernetes/kubelet.conf"
#
# Public entrypoint:
#   make repair-sno-baseline
set -euo pipefail

NODE="${NODE:-}"
FILE="${FILE:-/etc/kubernetes/kubelet.conf}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1200}"
SLEEP_SECONDS="${SLEEP_SECONDS:-20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

autodetect_node() {
	if [[ -n "$NODE" ]]; then
		return
	fi
	local nodes count
	nodes="$(oc get nodes --request-timeout=10s -o name 2>/dev/null | sed 's#^node/##')"
	count="$(printf '%s\n' "$nodes" | sed '/^$/d' | wc -l | tr -d ' ')"
	case "$count" in
		1)
			NODE="$nodes"
			echo "Auto-detected NODE=$NODE"
			;;
		0) die "set NODE=<node-name> (could not auto-detect from oc get nodes)" ;;
		*) die "set NODE=<node-name> (multiple nodes found: $(printf '%s' "$nodes" | tr '\n' ' '))" ;;
	esac
}

decode_data_url() {
	local source="$1" output="$2"
	python3 - "$source" "$output" <<'PY'
import base64
import sys
import urllib.parse

source, output = sys.argv[1], sys.argv[2]
if not source.startswith("data:") or "," not in source:
    raise SystemExit("unsupported MachineConfig file source")
header, data = source.split(",", 1)
blob = base64.b64decode(data) if ";base64" in header else urllib.parse.unquote_to_bytes(data)
with open(output, "wb") as f:
    f.write(blob)
PY
}

host_file_b64() {
	local file="$1"
	oc debug "node/${NODE}" --quiet -- chroot /host bash -c "base64 -w0 '$file'" 2>/dev/null
}

restore_host_file() {
	local expected="$1" mode_octal="$2"
	local payload
	payload="$(base64 -w0 "$expected")"
	local remote_script
	remote_script="$(cat <<NODE_SCRIPT
set -euo pipefail
path='$FILE'
mode='$mode_octal'
backup_dir="/var/tmp/mco-drift-backups"
mkdir -p "\$backup_dir"
backup="\$backup_dir/\$(basename "\$path").\$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "\$path" "\$backup"
tmp="\$(mktemp /tmp/mco-drift.XXXXXX)"
base64 -d > "\$tmp" <<'PAYLOAD'
$payload
PAYLOAD
install -o root -g root -m "\$mode" "\$tmp" "\$path"
rm -f "\$tmp"
echo "backup=\$backup"
stat -c "restored=%n mode=%a bytes=%s" "\$path"
NODE_SCRIPT
)"
	oc debug "node/${NODE}" --quiet -- chroot /host bash -c "$remote_script"
}

validate_until_ready() {
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	while (( SECONDS < deadline )); do
		if CATALOGSOURCE="${CATALOGSOURCE:-cs-redhat-operator-index-v4-20}" bash "$SCRIPT_DIR/validate-sno-baseline.sh"; then
			return 0
		fi
		echo "Waiting ${SLEEP_SECONDS}s for MCO/SNO baseline to converge..."
		sleep "$SLEEP_SECONDS"
	done
	echo "ERROR: SNO baseline did not converge within ${WAIT_TIMEOUT}s" >&2
	return 1
}

need oc
need jq
need python3
need base64
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"
[[ "$FILE" == "/etc/kubernetes/kubelet.conf" ]] || die "this repair only supports FILE=/etc/kubernetes/kubelet.conf"
autodetect_node

state="$(oc get node "$NODE" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/state}' 2>/dev/null || true)"
reason="$(oc get node "$NODE" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/reason}' 2>/dev/null || true)"
current_config="$(oc get node "$NODE" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}' 2>/dev/null || true)"
[[ -n "$current_config" ]] || die "node/$NODE has no machineconfiguration.openshift.io/currentConfig annotation"

if [[ "$state" != "Degraded" || "$reason" != *"content mismatch for file \"${FILE}\""* ]]; then
	echo "No supported kubelet.conf drift repair needed for node/$NODE"
	echo "state=${state:-<empty>}"
	echo "reason=${reason:-<empty>}"
	exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
expected_file="$tmpdir/expected"
actual_file="$tmpdir/actual"

source="$(oc get machineconfig "$current_config" -o json \
	| jq -r --arg path "$FILE" '.spec.config.storage.files[]? | select(.path == $path) | .contents.source // empty')"
[[ -n "$source" ]] || die "machineconfig/$current_config does not manage $FILE"
mode_decimal="$(oc get machineconfig "$current_config" -o json \
	| jq -r --arg path "$FILE" '.spec.config.storage.files[]? | select(.path == $path) | .mode // 420')"
mode_octal="$(printf '%04o' "$mode_decimal")"

decode_data_url "$source" "$expected_file"
host_file_b64 "$FILE" | base64 -d > "$actual_file"

if cmp -s "$expected_file" "$actual_file"; then
	echo "$FILE already matches machineconfig/$current_config"
else
	echo "Repairing $FILE on node/$NODE from machineconfig/$current_config"
	wc -c "$expected_file" "$actual_file" | sed 's/^/  /'
	sha256sum "$expected_file" "$actual_file" | sed 's/^/  /'
	restore_host_file "$expected_file" "$mode_octal"
fi

validate_until_ready
