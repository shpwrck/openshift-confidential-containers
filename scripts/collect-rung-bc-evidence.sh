#!/usr/bin/env bash
# Collect non-secret evidence for rung-b/c hardware proof runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${ARTIFACT_DIR}/evidence-$(date -u +%Y%m%dT%H%M%SZ)}"
PODS="${PODS:-rung-b-encrypted rung-c-signed negtest-rung-b negtest-rung-c}"
TRUSTEE_LOG_TAIL="${TRUSTEE_LOG_TAIL:-1000}"
POD_LOG_TAIL="${POD_LOG_TAIL:-200}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
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

write_redacted_secret() {
	local secret="$1"
	local out="${EVIDENCE_DIR}/trustee/secrets/${secret}.redacted.json"
	local raw
	if ! raw="$(oc -n "$TRUSTEE_NS" get secret "$secret" -o json 2>/dev/null)"; then
		printf 'missing\n' > "${EVIDENCE_DIR}/trustee/secrets/${secret}.missing"
		return
	fi
	redact_secret_json <<<"$raw" > "$out"
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

if [[ "${1:-}" == "redact-secret-json" ]]; then
	[[ "$#" -eq 1 ]] || die "usage: $0 redact-secret-json"
	need jq
	redact_secret_json
	exit 0
fi

need oc
need jq
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

mkdir -p \
	"${EVIDENCE_DIR}/cluster" \
	"${EVIDENCE_DIR}/pods" \
	"${EVIDENCE_DIR}/trustee/secrets" \
	"${EVIDENCE_DIR}/trustee/config"

{
	echo "captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "namespace=${NS}"
	echo "trustee_namespace=${TRUSTEE_NS}"
	echo "artifact_dir=${ARTIFACT_DIR}"
	echo "evidence_dir=${EVIDENCE_DIR}"
	echo "pods=${PODS}"
	echo "oc_user=$(oc whoami 2>/dev/null || true)"
} > "${EVIDENCE_DIR}/summary.env"

record "cluster/whoami.txt" oc whoami
record "cluster/version.txt" oc version
record "cluster/clusterversion.yaml" oc get clusterversion -o yaml
record "cluster/runtimeclasses.yaml" oc get runtimeclass -o yaml
record "cluster/workload-events.txt" oc -n "$NS" get events --sort-by=.lastTimestamp -o wide
record "trustee/events.txt" oc -n "$TRUSTEE_NS" get events --sort-by=.lastTimestamp -o wide

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

if [[ -f "${ARTIFACT_DIR}/rung-bc-images.json" ]]; then
	cp "${ARTIFACT_DIR}/rung-bc-images.json" "${EVIDENCE_DIR}/rung-bc-images.json"
fi

echo "Rung b/c evidence written to ${EVIDENCE_DIR}"
