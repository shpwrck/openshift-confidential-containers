#!/usr/bin/env bash
# Collect non-secret evidence for rung-b/c hardware proof runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${ARTIFACT_DIR}/evidence-$(date -u +%Y%m%dT%H%M%SZ)}"
PODS="${PODS:-rung-a-secret rung-b-encrypted rung-c-signed negtest-rung-a negtest-rung-b negtest-rung-c negtest-air-gap}"
TRUSTEE_LOG_TAIL="${TRUSTEE_LOG_TAIL:-1000}"
POD_LOG_TAIL="${POD_LOG_TAIL:-200}"
MIRROR_LOG_TAIL="${MIRROR_LOG_TAIL:-1000}"
MIRROR_LOG_FILES="${MIRROR_LOG_FILES:-/var/log/nginx/access.log /var/log/nginx/error.log /var/log/mirror-bootstrap.log /opt/mirror/oc-mirror-push.log}"
MIRROR_CONTAINER_NAMES="${MIRROR_CONTAINER_NAMES:-quay-app quay registry mirror-registry}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
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

record() {
	local file="$1"
	shift
	{
		printf '$'
		printf ' %q' "$@"
		printf '\n'
		"$@"
	} > "${EVIDENCE_DIR}/${file}" 2>&1 || true
}

record_log_file() {
	local path="$1" safe_name
	safe_name="$(printf '%s' "$path" | sed 's#^/##; s#[^A-Za-z0-9_.-]#_#g')"
	if ! run_readable "$path" tail -n "$MIRROR_LOG_TAIL" > "${EVIDENCE_DIR}/mirror/files/${safe_name}" 2>&1; then
		printf 'missing or unreadable: %s\n' "$path" > "${EVIDENCE_DIR}/mirror/files/${safe_name}.missing"
	fi
}

record_mirror_container_log() {
	local name="$1" runtime=""
	if command -v podman >/dev/null; then
		runtime=podman
	elif command -v docker >/dev/null; then
		runtime=docker
	else
		printf 'podman/docker not on PATH\n' > "${EVIDENCE_DIR}/mirror/containers/${name}.missing"
		return
	fi

	if "$runtime" container inspect "$name" >/dev/null 2>&1; then
		"$runtime" logs --tail "$MIRROR_LOG_TAIL" "$name" > "${EVIDENCE_DIR}/mirror/containers/${name}.log" 2>&1 || true
	elif command -v sudo >/dev/null && sudo -n "$runtime" container inspect "$name" >/dev/null 2>&1; then
		{ sudo -n "$runtime" logs --tail "$MIRROR_LOG_TAIL" "$name"; } > "${EVIDENCE_DIR}/mirror/containers/${name}.log" 2>&1 || true
	else
		printf 'missing container: %s\n' "$name" > "${EVIDENCE_DIR}/mirror/containers/${name}.missing"
	fi
}

redact_secret_json() {
	jq '{
		apiVersion,
		kind,
		type,
		metadata: {
			name: .metadata.name,
			namespace: .metadata.namespace,
			labels: (.metadata.labels // {}),
			annotationKeys: ((.metadata.annotations // {}) | keys)
		},
		dataKeys: ((.data // {}) | keys)
	}'
}

secret_data_lengths() {
	local key value bytes
	jq -r '(.data // {}) | to_entries[] | [.key, .value] | @tsv' | while IFS=$'\t' read -r key value; do
		if bytes="$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')"; then
			printf '%s\t%s\n' "$key" "$bytes"
		else
			printf '%s\tdecode-error\n' "$key"
		fi
	done
}

write_redacted_secret() {
	local secret="$1"
	local out="${EVIDENCE_DIR}/trustee/secrets/${secret}.redacted.json"
	local lengths_out="${EVIDENCE_DIR}/trustee/secrets/${secret}.data-lengths.tsv"
	local raw
	if ! raw="$(oc -n "$TRUSTEE_NS" get secret "$secret" -o json 2>/dev/null)"; then
		printf 'missing\n' > "${EVIDENCE_DIR}/trustee/secrets/${secret}.missing"
		return
	fi
	redact_secret_json <<<"$raw" > "$out"
	secret_data_lengths <<<"$raw" > "$lengths_out"
}

decode_pod_initdata() {
	local pod="$1"
	local pod_json="${EVIDENCE_DIR}/pods/${pod}.json"
	local initdata
	[[ -s "$pod_json" ]] || return
	initdata="$(jq -r '.metadata.annotations["io.katacontainers.config.hypervisor.cc_init_data"] // ""' "$pod_json")"
	[[ -n "$initdata" ]] || return
	printf '%s\n' "$initdata" > "${EVIDENCE_DIR}/pods/${pod}.cc_init_data.b64"
	bash "$REPO_ROOT/scripts/encode-initdata.sh" decode "$initdata" \
		> "${EVIDENCE_DIR}/pods/${pod}.initdata.toml" \
		2> "${EVIDENCE_DIR}/pods/${pod}.initdata.decode.err" || true
}

copy_artifact_handoff() {
	local artifact_dir="$1" evidence_dir="$2" artifact
	for artifact in rung-bc-images.json rung-bc.env; do
		if [[ -f "${artifact_dir}/${artifact}" ]]; then
			cp "${artifact_dir}/${artifact}" "${evidence_dir}/${artifact}"
		fi
	done
}

write_summary() {
	local out="$1" git_head="" git_branch="" git_dirty="" tool
	if command -v git >/dev/null && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git_head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
		git_branch="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
		if [[ -n "$(git -C "$REPO_ROOT" status --short 2>/dev/null)" ]]; then
			git_dirty=true
		else
			git_dirty=false
		fi
	fi

	{
		echo "captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "namespace=${NS}"
		echo "trustee_namespace=${TRUSTEE_NS}"
		echo "artifact_dir=${ARTIFACT_DIR}"
		echo "evidence_dir=${EVIDENCE_DIR}"
		echo "pods=${PODS}"
		echo "mirror_log_files=${MIRROR_LOG_FILES}"
		echo "mirror_container_names=${MIRROR_CONTAINER_NAMES}"
		echo "oc_user=$(oc whoami 2>/dev/null || true)"
		echo "repo_root=${REPO_ROOT}"
		echo "repo_git_head=${git_head}"
		echo "repo_git_branch=${git_branch}"
		echo "repo_git_dirty=${git_dirty}"
		for tool in oc jq skopeo cosign podman docker; do
			echo "tool_${tool}=$(command -v "$tool" 2>/dev/null || true)"
		done
	} > "$out"
}

if [[ "${1:-}" == "redact-secret-json" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 redact-secret-json"
	need jq
	redact_secret_json
	exit 0
fi

if [[ "${1:-}" == "secret-data-lengths" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 secret-data-lengths"
	need jq
	need base64
	secret_data_lengths
	exit 0
fi

if [[ "${1:-}" == "copy-artifact-handoff" ]]; then
	[[ "$#" -eq 3 ]] || die "usage: $0 copy-artifact-handoff <artifact-dir> <evidence-dir>"
	mkdir -p "$3"
	copy_artifact_handoff "$2" "$3"
	exit 0
fi

if [[ "${1:-}" == "write-summary" ]]; then
	[[ "$#" -eq 2 ]] || die "usage: $0 write-summary <summary.env>"
	write_summary "$2"
	exit 0
fi

need oc
need jq
need base64
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

mkdir -p \
	"${EVIDENCE_DIR}/cluster" \
	"${EVIDENCE_DIR}/mirror/files" \
	"${EVIDENCE_DIR}/mirror/containers" \
	"${EVIDENCE_DIR}/pods" \
	"${EVIDENCE_DIR}/repo" \
	"${EVIDENCE_DIR}/trustee/secrets" \
	"${EVIDENCE_DIR}/trustee/config"

write_summary "${EVIDENCE_DIR}/summary.env"

record "cluster/whoami.txt" oc whoami
record "cluster/version.txt" oc version
record "cluster/clusterversion.yaml" oc get clusterversion -o yaml
record "cluster/runtimeclasses.yaml" oc get runtimeclass -o yaml
record "cluster/workload-events.txt" oc -n "$NS" get events --sort-by=.lastTimestamp -o wide
if command -v git >/dev/null && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	record "repo/git-status.txt" git -C "$REPO_ROOT" status --short
	record "repo/git-head.txt" git -C "$REPO_ROOT" show --no-patch --format=fuller HEAD
fi
record "trustee/events.txt" oc -n "$TRUSTEE_NS" get events --sort-by=.lastTimestamp -o wide

for log_file in $MIRROR_LOG_FILES; do
	record_log_file "$log_file"
done
for container_name in $MIRROR_CONTAINER_NAMES; do
	record_mirror_container_log "$container_name"
done

for pod in $PODS; do
	if oc -n "$NS" get pod "$pod" -o json > "${EVIDENCE_DIR}/pods/${pod}.json" 2> "${EVIDENCE_DIR}/pods/${pod}.get.err"; then
		record "pods/${pod}.yaml" oc -n "$NS" get pod "$pod" -o yaml
		record "pods/${pod}.describe.txt" oc -n "$NS" describe pod "$pod"
		record "pods/${pod}.logs.txt" oc -n "$NS" logs "pod/${pod}" --all-containers --prefix=true --tail="$POD_LOG_TAIL"
		decode_pod_initdata "$pod"
	else
		printf 'missing\n' > "${EVIDENCE_DIR}/pods/${pod}.missing"
	fi
done

record "trustee/kbsconfig.yaml" oc -n "$TRUSTEE_NS" get kbsconfig kbsconfig -o yaml
record "trustee/deployment.yaml" oc -n "$TRUSTEE_NS" get deployment trustee-deployment -o yaml
record "trustee/logs.txt" oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --tail="$TRUSTEE_LOG_TAIL"
for configmap in kbs-config resource-policy attestation-policy rvps-reference-values; do
	record "trustee/config/${configmap}.yaml" oc -n "$TRUSTEE_NS" get configmap "$configmap" -o yaml
done

for secret in image-key sig-public-key security-policy registry-configuration credential regcred attestation-status sample; do
	write_redacted_secret "$secret"
done
while IFS= read -r vcek_secret; do
	[[ -n "$vcek_secret" ]] || continue
	write_redacted_secret "${vcek_secret#secret/}"
done < <(oc -n "$TRUSTEE_NS" get secret -o name 2>/dev/null | grep '^secret/vcek-' || true)

copy_artifact_handoff "$ARTIFACT_DIR" "$EVIDENCE_DIR"

echo "Rung b/c evidence written to ${EVIDENCE_DIR}"
