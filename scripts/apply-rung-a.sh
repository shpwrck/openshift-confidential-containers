#!/usr/bin/env bash
# Render SNO initdata, launch rung-a, and wait until the confidential pod is running.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.rig.local:8443}"
MIRROR_CA="${MIRROR_CA:-/opt/mirror/ca/rootCA.pem}"
MIRROR_DOMAIN="${MIRROR_DOMAIN:-rig.local}"
MIRROR_DNS_UPSTREAM="${MIRROR_DNS_UPSTREAM:-192.168.66.10}"
KBS_URL="${KBS_URL:-http://kbs-service.${TRUSTEE_NS}.svc:8080}"
RUNG_A_IMAGE="${RUNG_A_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal@sha256:4ba37413a8284073eb28f1987fdf8f7b9cc3d301807cdd79e10ab5b98bd57a63}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
CATALOGSOURCE="${CATALOGSOURCE:-cs-redhat-operator-index-v4-20}"

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
	CATALOGSOURCE="$CATALOGSOURCE" bash "$REPO_ROOT/scripts/validate-sno-baseline.sh" >/tmp/apply-rung-a-baseline.log 2>&1
}

runtimeclass_ok() {
	oc get runtimeclass kata-cc -o jsonpath='{.handler}' 2>/dev/null | grep -qx 'kata-snp'
}

trustee_available() {
	oc -n "$TRUSTEE_NS" rollout status deployment/trustee-deployment --timeout=10s >/dev/null 2>&1
}

pod_ready() {
	oc -n "$NS" wait pod/rung-a-secret --for=condition=Ready --timeout=10s >/dev/null 2>&1
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
image_security_policy_uri = "kbs:///default/security-policy/test"
registry_configuration_uri = "kbs:///default/registry-configuration/test"
extra_root_certificates = ["""
${mirror_ca}
"""]
'''
EOF
}

render_pod() {
	local initdata="$1" out="$2" patch
	patch="$(jq -nc \
		--arg initdata "$initdata" \
		--arg image "$RUNG_A_IMAGE" \
		'{
			metadata: {annotations: {"io.katacontainers.config.hypervisor.cc_init_data": $initdata}},
			spec: {
				initContainers: [{name: "attestation-gate", image: $image}],
				containers: [{name: "app", image: $image}]
			}
		}')"
	oc patch --local -f "$REPO_ROOT/gitops/base/workloads/rung-a-secret-pod.yaml" \
		--type=strategic -p "$patch" -o yaml > "$out"
}

collect_failure_context() {
	echo
	echo "== rung-a pod =="
	oc -n "$NS" get pod rung-a-secret -o wide || true
	oc -n "$NS" describe pod rung-a-secret || true
	echo
	echo "== Trustee logs =="
	oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --tail=160 || true
}

need oc
need jq
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

cd "$REPO_ROOT"
tmpdir="$(mktemp -d)"

wait_until "SNO baseline" sno_baseline_ok || { cat /tmp/apply-rung-a-baseline.log >&2; exit 1; }
wait_until "kata-cc runtime class" runtimeclass_ok
wait_until "Trustee deployment available" trustee_available

echo "Configuring rig.local DNS forwarding to ${MIRROR_DNS_UPSTREAM}"
ensure_dns_forwarder

render_initdata "$(read_file "$MIRROR_CA")" "$tmpdir/initdata.toml"
initdata="$(bash "$REPO_ROOT/scripts/encode-initdata.sh" encode "$tmpdir/initdata.toml")"
render_pod "$initdata" "$tmpdir/rung-a-secret.yaml"

oc -n "$NS" delete pod rung-a-secret --ignore-not-found --wait=true
oc apply -f "$tmpdir/rung-a-secret.yaml"

if ! wait_until "rung-a-secret pod Ready" pod_ready; then
	collect_failure_context
	exit 1
fi

echo
echo "== attestation gate log =="
oc -n "$NS" logs pod/rung-a-secret -c attestation-gate
echo
echo "== app log =="
oc -n "$NS" logs pod/rung-a-secret -c app --tail=20
echo
echo "Rung-a confidential pod is running"
