#!/usr/bin/env bash
# Reproduce and collect evidence for the rung-b direct encrypted-image pull blocker.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.rig.local:8443}"
MIRROR_DNS_UPSTREAM="${MIRROR_DNS_UPSTREAM:-192.168.66.10}"
KBS_URL="${KBS_URL:-http://kbs-service.${TRUSTEE_NS}.svc:8080}"
RUNG_B_IMAGE="${RUNG_B_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b:encrypted}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-kbs:///default/image-key/rung-b}"
RUNG_B_POLICY_URI="${RUNG_B_POLICY_URI:-kbs:///default/security-policy/test}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
DIAG_DIR="${DIAG_DIR:-${ARTIFACT_DIR}/rung-b-direct-pull-$(date -u +%Y%m%dT%H%M%SZ)}"
POD_NAME="${POD_NAME:-rung-b-direct-pull-diag}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
POLL_SECONDS="${POLL_SECONDS:-5}"
KEEP_DIAG_POD="${KEEP_DIAG_POD:-0}"
TRUSTEE_LOG_TAIL="${TRUSTEE_LOG_TAIL:-600}"
CRIO_LOG_TAIL="${CRIO_LOG_TAIL:-600}"
MIRROR_LOG_TAIL="${MIRROR_LOG_TAIL:-600}"
MIRROR_LOG_FILES="${MIRROR_LOG_FILES:-/var/log/nginx/access.log /var/log/nginx/error.log /var/log/mirror-bootstrap.log /opt/mirror/oc-mirror-push.log}"
MIRROR_CONTAINER_NAMES="${MIRROR_CONTAINER_NAMES:-quay-app quay registry mirror-registry}"
APPLY_RUNG_B_SCRIPT="${APPLY_RUNG_B_SCRIPT:-${REPO_ROOT}/scripts/apply-rung-b.sh}"

HOST_PULL_BLOCKER_RE='should be decrypted|destination specifies a digest|missing private key needed for decryption|private key needed for decryption'
MIRROR_CRIO_RUNG_B_MANIFEST_COUNT=0
MIRROR_CRIO_RUNG_B_BLOB_COUNT=0
MIRROR_GUEST_RUNG_B_MANIFEST_COUNT=0
MIRROR_GUEST_RUNG_B_BLOB_COUNT=0

die() {
	echo "ERROR: $*" >&2
	exit 2
}

usage() {
	cat <<EOF
Usage: diagnose-rung-b-direct-pull.sh

Runs a short hardware diagnostic for the current rung-b direct encrypted-image blocker.
It expects oc to be logged into the rig cluster and RUNG_B_IMAGE to be a digest-pinned
encrypted image reference.

Key env:
  NS                    workload namespace (default: default)
  TRUSTEE_NS            Trustee namespace (default: trustee-operator-system)
  RUNG_B_IMAGE          digest-pinned encrypted image
  RUNG_B_KEY_ID         kbs:/// URI for the encrypted image key
  RUNG_B_POLICY_URI     initdata image security policy URI
  DIAG_DIR              output directory
  WAIT_TIMEOUT          seconds to wait for the known blocker (default: 180)
  KEEP_DIAG_POD         set 1 to keep the diagnostic pod
  MIRROR_LOG_FILES      host mirror log files to tail when readable
  MIRROR_CONTAINER_NAMES mirror container names to inspect with podman/docker

Exit codes:
  0  reproduced the known host-side blocker before any image-key request
  1  blocker did not reproduce cleanly, or the pod unexpectedly ran
  2  local setup/usage error
EOF
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

require_digest_ref() {
	local image="$1"
	[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || die "RUNG_B_IMAGE must be a sha256 digest ref: $image"
}

kbs_uri_resource_path() {
	local uri="$1" path
	[[ "$uri" == kbs:///* ]] || die "RUNG_B_KEY_ID must start with kbs:///: $uri"
	path="${uri#kbs:///}"
	[[ -n "$path" && "$path" != /* ]] || die "RUNG_B_KEY_ID has no resource path: $uri"
	printf '%s\n' "$path"
}

image_repo_path() {
	local image="$1" without_digest last_segment
	without_digest="${image%@*}"
	last_segment="${without_digest##*/}"
	if [[ "$last_segment" == *:* ]]; then
		without_digest="${without_digest%:*}"
	fi
	if [[ "$without_digest" == */* ]]; then
		printf '%s\n' "${without_digest#*/}"
	else
		printf '%s\n' "$without_digest"
	fi
}

image_digest() {
	local image="$1"
	if [[ "$image" =~ @(sha256:[0-9a-f]{64})$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
}

record_cmd() {
	local out="$1"
	shift
	{
		printf '$'
		printf ' %q' "$@"
		printf '\n'
		"$@"
	} > "$out" 2>&1 || true
}

run_readable() {
	local path="$1"
	if [[ -r "$path" ]]; then
		shift
		"$@" "$path"
	elif command -v sudo >/dev/null && sudo -n test -r "$path" 2>/dev/null; then
		shift
		sudo -n "$@" "$path"
	else
		return 1
	fi
}

record_mirror_log_file() {
	local path="$1" safe_name
	safe_name="$(printf '%s' "$path" | sed 's#^/##; s#[^A-Za-z0-9_.-]#_#g')"
	if ! run_readable "$path" tail -n "$MIRROR_LOG_TAIL" > "${DIAG_DIR}/mirror/files/${safe_name}" 2>&1; then
		printf 'missing or unreadable: %s\n' "$path" > "${DIAG_DIR}/mirror/files/${safe_name}.missing"
	fi
}

record_mirror_container_log() {
	local name="$1" runtime=""
	if command -v podman >/dev/null; then
		runtime=podman
	elif command -v docker >/dev/null; then
		runtime=docker
	else
		printf 'podman/docker not on PATH\n' > "${DIAG_DIR}/mirror/containers/${name}.missing"
		return
	fi

	if "$runtime" container inspect "$name" >/dev/null 2>&1; then
		"$runtime" logs --tail "$MIRROR_LOG_TAIL" "$name" > "${DIAG_DIR}/mirror/containers/${name}.log" 2>&1 || true
	elif command -v sudo >/dev/null && sudo -n "$runtime" container inspect "$name" >/dev/null 2>&1; then
		{ sudo -n "$runtime" logs --tail "$MIRROR_LOG_TAIL" "$name"; } > "${DIAG_DIR}/mirror/containers/${name}.log" 2>&1 || true
	else
		printf 'missing container: %s\n' "$name" > "${DIAG_DIR}/mirror/containers/${name}.missing"
	fi
}

collect_mirror_logs() {
	local path name
	mkdir -p "${DIAG_DIR}/mirror/files" "${DIAG_DIR}/mirror/containers"
	for path in $MIRROR_LOG_FILES; do
		record_mirror_log_file "$path"
	done
	for name in $MIRROR_CONTAINER_NAMES; do
		record_mirror_container_log "$name"
	done
}

mirror_log_context() {
	local file
	for file in \
		"${DIAG_DIR}"/mirror/files/* \
		"${DIAG_DIR}"/mirror/containers/*.log; do
		[[ -f "$file" ]] && cat "$file"
		printf '\n'
	done
}

mirror_count() {
	local context="$1" needle="$2" agent="$3"
	awk -v needle="$needle" -v agent="$agent" '
		index($0, needle) && index($0, agent) { count++ }
		END { print count + 0 }
	' <<<"$context"
}

write_mirror_summary() {
	local context repo digest
	context="$(mirror_log_context)"
	repo="$(image_repo_path "$RUNG_B_IMAGE")"
	digest="$(image_digest "$RUNG_B_IMAGE")"

	if [[ -z "$(tr -d '[:space:]' <<<"$context")" || -z "$repo" || -z "$digest" ]]; then
		cat > "${DIAG_DIR}/mirror/summary.tsv" <<EOF
signal	count
mirror_context_available	0
EOF
		return
	fi

	MIRROR_CRIO_RUNG_B_MANIFEST_COUNT="$(mirror_count "$context" "${repo}/manifests/${digest}" "cri-o/")"
	MIRROR_CRIO_RUNG_B_BLOB_COUNT="$(mirror_count "$context" "${repo}/blobs/" "cri-o/")"
	MIRROR_GUEST_RUNG_B_MANIFEST_COUNT="$(mirror_count "$context" "${repo}/manifests/${digest}" "oci-client/")"
	MIRROR_GUEST_RUNG_B_BLOB_COUNT="$(mirror_count "$context" "${repo}/blobs/" "oci-client/")"
	cat > "${DIAG_DIR}/mirror/summary.tsv" <<EOF
signal	count
mirror_context_available	1
crio_rung_b_manifest	${MIRROR_CRIO_RUNG_B_MANIFEST_COUNT}
crio_rung_b_blob	${MIRROR_CRIO_RUNG_B_BLOB_COUNT}
guest_rung_b_manifest	${MIRROR_GUEST_RUNG_B_MANIFEST_COUNT}
guest_rung_b_blob	${MIRROR_GUEST_RUNG_B_BLOB_COUNT}
EOF
}

pod_phase() {
	oc -n "$NS" get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

pod_node() {
	oc -n "$NS" get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true
}

collect_text_context() {
	{
		echo "== pod =="
		oc -n "$NS" get pod "$POD_NAME" -o wide 2>/dev/null || true
		echo
		echo "== describe =="
		oc -n "$NS" describe pod "$POD_NAME" 2>/dev/null || true
		echo
		echo "== events =="
		oc -n "$NS" get events --field-selector "involvedObject.name=${POD_NAME}" --sort-by=.lastTimestamp -o wide 2>/dev/null || true
		echo
		echo "== trustee logs since ${SINCE_TIME} =="
		oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --since-time="$SINCE_TIME" --tail="$TRUSTEE_LOG_TAIL" 2>/dev/null || true
	}
}

write_summary() {
	local phase="$1" node="$2" host_blocker="$3" image_key_requested="$4" exit_class="$5"
	cat > "${DIAG_DIR}/summary.env" <<EOF
timestamp_utc=${SINCE_TIME}
namespace=${NS}
trustee_namespace=${TRUSTEE_NS}
pod_name=${POD_NAME}
node=${node}
rung_b_image=${RUNG_B_IMAGE}
rung_b_key_id=${RUNG_B_KEY_ID}
rung_b_key_resource=${RUNG_B_KEY_RESOURCE}
rung_b_policy_uri=${RUNG_B_POLICY_URI}
phase=${phase}
host_pull_blocker_seen=${host_blocker}
image_key_request_seen=${image_key_requested}
mirror_crio_rung_b_manifest_count=${MIRROR_CRIO_RUNG_B_MANIFEST_COUNT}
mirror_crio_rung_b_blob_count=${MIRROR_CRIO_RUNG_B_BLOB_COUNT}
mirror_guest_rung_b_manifest_count=${MIRROR_GUEST_RUNG_B_MANIFEST_COUNT}
mirror_guest_rung_b_blob_count=${MIRROR_GUEST_RUNG_B_BLOB_COUNT}
classification=${exit_class}
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

need oc
need grep
require_digest_ref "$RUNG_B_IMAGE"
[[ -x "$APPLY_RUNG_B_SCRIPT" || -f "$APPLY_RUNG_B_SCRIPT" ]] || die "missing apply script: $APPLY_RUNG_B_SCRIPT"
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

mkdir -p "$DIAG_DIR"
RUNG_B_KEY_RESOURCE="$(kbs_uri_resource_path "$RUNG_B_KEY_ID")"
SINCE_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Writing diagnostic output to ${DIAG_DIR}"
env NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
	MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" \
	RUNG_B_KEY_ID="$RUNG_B_KEY_ID" IMAGE_SECURITY_POLICY_URI="$RUNG_B_POLICY_URI" \
	RUNG_B_IMAGE="$RUNG_B_IMAGE" POD_NAME="$POD_NAME" RENDER_ONLY=1 \
	bash "$APPLY_RUNG_B_SCRIPT" > "${DIAG_DIR}/pod.yaml"

record_cmd cluster-info.txt oc cluster-info
record_cmd runtimeclass-kata-cc.yaml oc get runtimeclass kata-cc -o yaml
record_cmd trustee-rollout.txt oc -n "$TRUSTEE_NS" rollout status deployment/trustee-deployment --timeout=30s

oc -n "$NS" delete pod "$POD_NAME" --ignore-not-found --wait=true >/dev/null 2>&1 || true
oc apply -f "${DIAG_DIR}/pod.yaml" > "${DIAG_DIR}/apply.txt"

deadline=$((SECONDS + WAIT_TIMEOUT))
phase=""
host_blocker=0
while (( SECONDS < deadline )); do
	phase="$(pod_phase)"
	if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
		break
	fi
	if collect_text_context | grep -Eiq "$HOST_PULL_BLOCKER_RE"; then
		host_blocker=1
		break
	fi
	sleep "$POLL_SECONDS"
done

phase="$(pod_phase)"
node="$(pod_node)"
collect_text_context > "${DIAG_DIR}/context.txt"
record_cmd pod.json oc -n "$NS" get pod "$POD_NAME" -o json
record_cmd pod.yaml.live oc -n "$NS" get pod "$POD_NAME" -o yaml
record_cmd events.txt oc -n "$NS" get events --field-selector "involvedObject.name=${POD_NAME}" --sort-by=.lastTimestamp -o wide
record_cmd trustee.log oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --since-time="$SINCE_TIME" --tail="$TRUSTEE_LOG_TAIL"

if [[ -n "$node" ]]; then
	record_cmd crio-node.log oc adm node-logs "$node" -u crio --tail="$CRIO_LOG_TAIL"
fi
collect_mirror_logs
write_mirror_summary

if grep -Eiq "$HOST_PULL_BLOCKER_RE" "${DIAG_DIR}/context.txt"; then
	host_blocker=1
fi

image_key_requested=0
if grep -Fq "resource/${RUNG_B_KEY_RESOURCE}" "${DIAG_DIR}/trustee.log" "${DIAG_DIR}/context.txt" 2>/dev/null; then
	image_key_requested=1
fi

if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
	echo "UNEXPECTED: pod reached ${phase}; direct encrypted-image path may be unblocked." | tee "${DIAG_DIR}/classification.txt"
	write_summary "$phase" "$node" "$host_blocker" "$image_key_requested" "unexpected-running"
	echo "Keeping ${POD_NAME} for follow-up evidence."
	exit 1
fi

if [[ "$host_blocker" == "1" && "$image_key_requested" == "0" ]]; then
	echo "REPRODUCED: host-side encrypted-layer pull blocked before guest image-key request." | tee "${DIAG_DIR}/classification.txt"
	write_summary "$phase" "$node" "$host_blocker" "$image_key_requested" "known-host-pull-blocker"
	if [[ "$KEEP_DIAG_POD" != "1" ]]; then
		oc -n "$NS" delete pod "$POD_NAME" --ignore-not-found >/dev/null 2>&1 || true
	fi
	exit 0
fi

echo "INCONCLUSIVE: known host-side blocker did not reproduce cleanly." | tee "${DIAG_DIR}/classification.txt"
write_summary "$phase" "$node" "$host_blocker" "$image_key_requested" "inconclusive"
echo "Keeping ${POD_NAME} for follow-up evidence."
exit 1
