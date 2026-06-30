#!/usr/bin/env bash
# Render and optionally apply the rung-b/rung-c image proof workloads.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNG="${RUNG:-}"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.rig.local:8443}"
MIRROR_CA="${MIRROR_CA:-/opt/mirror/ca/rootCA.pem}"
MIRROR_DOMAIN="${MIRROR_DOMAIN:-rig.local}"
MIRROR_DNS_UPSTREAM="${MIRROR_DNS_UPSTREAM:-192.168.66.10}"
KBS_URL="${KBS_URL:-http://kbs-service.${TRUSTEE_NS}.svc:8080}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
CATALOGSOURCE="${CATALOGSOURCE:-cs-redhat-operator-index-v4-20}"
RENDER_ONLY="${RENDER_ONLY:-0}"
TAMPER_INITDATA="${TAMPER_INITDATA:-0}"
REQUIRE_KBS_RESOURCE_LOGS="${REQUIRE_KBS_RESOURCE_LOGS:-1}"

tmpdir=""

die() {
	echo "ERROR: $*" >&2
	exit 2
}

require_digest_ref() {
	local var_name="$1" image="$2"
	if [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
		return
	fi
	die "${var_name} must be a sha256 digest ref for proof runs: ${image}. Source rung-bc-artifacts/rung-bc.env from make build-rung-images, or read the digest refs from rung-bc-artifacts/rung-bc-images.json."
}

kbs_uri_resource_path() {
	local uri="$1" path
	if [[ "$uri" != kbs:///* ]]; then
		die "KBS URI must start with kbs:///: $uri"
	fi
	path="${uri#kbs:///}"
	[[ -n "$path" && "$path" != /* ]] || die "KBS URI has no resource path: $uri"
	printf '%s\n' "$path"
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

sno_baseline_ok() {
	CATALOGSOURCE="$CATALOGSOURCE" bash "$REPO_ROOT/scripts/validate-sno-baseline.sh" >/tmp/apply-rung-image-baseline.log 2>&1
}

runtimeclass_ok() {
	oc get runtimeclass kata-cc -o jsonpath='{.handler}' 2>/dev/null | grep -qx 'kata-snp'
}

trustee_available() {
	oc -n "$TRUSTEE_NS" rollout status deployment/trustee-deployment --timeout=10s >/dev/null 2>&1
}

pod_ready() {
	oc -n "$NS" wait "pod/${POD_NAME}" --for=condition=Ready --timeout=10s >/dev/null 2>&1
}

ensure_dns_forwarder() {
	local servers patch
	servers="$(oc get dns.operator/default -o json | jq -c \
		--arg name "riglocal" \
		--arg zone "$MIRROR_DOMAIN" \
		--arg upstream "$MIRROR_DNS_UPSTREAM" \
		'((.spec.servers // []) | map(select(.name != $name)) + [{name:$name,zones:[$zone],forwardPlugin:{upstreams:[$upstream]}}])')"
	patch="$(jq -nc --argjson servers "$servers" '{spec:{servers:$servers}}')"
	oc patch dns.operator/default --type=merge -p "$patch" >/dev/null
	oc -n openshift-dns rollout status daemonset/dns-default --timeout=300s >/dev/null
}

render_initdata() {
	local mirror_ca="$1" out="$2"
	cat > "$out" <<EOF
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.kbs]
url = "${KBS_URL}"
'''

"cdh.toml" = '''
socket = "unix:///run/confidential-containers/cdh.sock"
[kbc]
name = "cc_kbc"
url = "${KBS_URL}"

[image]
authenticated_registry_credentials_uri = "kbs:///default/credential/test"
image_security_policy_uri = "${IMAGE_SECURITY_POLICY_URI}"
registry_configuration_uri = "kbs:///default/registry-configuration/test"
extra_root_certificates = ["""
${mirror_ca}
"""]
'''
EOF
	if [[ "$TAMPER_INITDATA" == "1" ]]; then
		{
			echo
			echo "# negative-test tamper: changes SNP HOST_DATA; do not regenerate RVPS"
		} >> "$out"
	fi
}

render_pod() {
	local initdata="$1" out="$2" patch
	patch="$(jq -nc \
		--arg name "$POD_NAME" \
		--arg namespace "$NS" \
		--arg initdata "$initdata" \
		--arg image "$RUNG_IMAGE" \
		'{
			metadata: {
				name: $name,
				namespace: $namespace,
				annotations: {"io.katacontainers.config.hypervisor.cc_init_data": $initdata}
			},
			spec: {
				containers: [{name: "app", image: $image}]
			}
		}')"
	oc patch --local -f "$BASE_MANIFEST" --type=strategic -p "$patch" -o yaml > "$out"
}

collect_failure_context() {
	echo
	echo "== ${POD_NAME} pod =="
	oc -n "$NS" get pod "$POD_NAME" -o wide || true
	oc -n "$NS" describe pod "$POD_NAME" || true
	echo
	echo "== Trustee logs =="
	oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --tail=240 || true
}

verify_kbs_resource_logs() {
	local logs resource missing=0
	logs="$(oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --tail=500 2>/dev/null || true)"
	for resource in "${EXPECTED_KBS_RESOURCES[@]}"; do
		if ! grep -Fq "resource/${resource}" <<<"$logs"; then
			echo "WARN: did not see KBS resource/${resource} in recent Trustee logs"
			missing=1
		fi
	done
	if [[ "$missing" == "1" && "$REQUIRE_KBS_RESOURCE_LOGS" == "1" ]]; then
		echo "ERROR: expected KBS resource fetch was not visible in recent logs" >&2
		return 1
	fi
	return 0
}

case "$RUNG" in
	b)
		BASE_MANIFEST="${BASE_MANIFEST:-$REPO_ROOT/gitops/base/workloads/rung-b-encrypted-pod.yaml}"
		POD_NAME="${POD_NAME:-rung-b-encrypted}"
		RUNG_IMAGE="${RUNG_B_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b:encrypted}"
		RUNG_IMAGE_VAR=RUNG_B_IMAGE
		RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-kbs:///default/image-key/rung-b}"
		IMAGE_SECURITY_POLICY_URI="${IMAGE_SECURITY_POLICY_URI:-kbs:///default/security-policy/test}"
		EXPECTED_KBS_RESOURCES=("$(kbs_uri_resource_path "$RUNG_B_KEY_ID")")
		;;
	c)
		BASE_MANIFEST="${BASE_MANIFEST:-$REPO_ROOT/gitops/base/workloads/rung-c-signed-pod.yaml}"
		POD_NAME="${POD_NAME:-rung-c-signed}"
		RUNG_IMAGE="${RUNG_C_IMAGE:-${MIRROR_REGISTRY}/coco/rung-c:signed}"
		RUNG_IMAGE_VAR=RUNG_C_IMAGE
		IMAGE_SECURITY_POLICY_URI="${IMAGE_SECURITY_POLICY_URI:-kbs:///default/security-policy/rung-c}"
		EXPECTED_KBS_RESOURCES=("$(kbs_uri_resource_path "$IMAGE_SECURITY_POLICY_URI")" default/sig-public-key/rung-c)
		;;
	*) die "set RUNG=b or RUNG=c" ;;
esac

require_digest_ref "$RUNG_IMAGE_VAR" "$RUNG_IMAGE"

need oc
need jq
[[ -f "$BASE_MANIFEST" ]] || die "missing base manifest: $BASE_MANIFEST"

cd "$REPO_ROOT"
tmpdir="$(mktemp -d)"
render_initdata "$(read_file "$MIRROR_CA")" "$tmpdir/initdata.toml"
initdata="$(bash "$REPO_ROOT/scripts/encode-initdata.sh" encode "$tmpdir/initdata.toml")"
render_pod "$initdata" "$tmpdir/pod.yaml"

if [[ "$RENDER_ONLY" == "1" ]]; then
	cat "$tmpdir/pod.yaml"
	exit 0
fi

oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

wait_until "SNO baseline" sno_baseline_ok || { cat /tmp/apply-rung-image-baseline.log >&2; exit 1; }
wait_until "kata-cc runtime class" runtimeclass_ok
wait_until "Trustee deployment available" trustee_available

echo "Configuring ${MIRROR_DOMAIN} DNS forwarding to ${MIRROR_DNS_UPSTREAM}"
ensure_dns_forwarder

oc -n "$NS" delete pod "$POD_NAME" --ignore-not-found --wait=true
oc apply -f "$tmpdir/pod.yaml"

if ! wait_until "${POD_NAME} pod Ready" pod_ready; then
	collect_failure_context
	exit 1
fi

verify_kbs_resource_logs

echo
echo "== app log =="
oc -n "$NS" logs "pod/${POD_NAME}" -c app --tail=20
echo
echo "Rung-${RUNG} confidential image pod is running"
