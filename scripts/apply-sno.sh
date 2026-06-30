#!/usr/bin/env bash
# Staged, idempotent SNO worker-side CoCo install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"
SLEEP_SECONDS="${SLEEP_SECONDS:-20}"
CATALOGSOURCE="${CATALOGSOURCE:-cs-redhat-operator-index-v4-20}"

log() {
	printf '\n== %s ==\n' "$*"
}

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
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

subscription_succeeded() {
	local ns="$1" sub="$2"
	local csv phase
	csv="$(oc -n "$ns" get subscription "$sub" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
	[[ -n "$csv" ]] || return 1
	phase="$(oc -n "$ns" get csv "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
	[[ "$phase" == "Succeeded" ]]
}

all_operator_csvs_succeeded() {
	subscription_succeeded openshift-nfd nfd &&
		subscription_succeeded cert-manager-operator openshift-cert-manager-operator &&
		subscription_succeeded openshift-sandboxed-containers-operator sandboxed-containers-operator &&
		subscription_succeeded trustee-operator-system trustee-operator &&
		subscription_succeeded openshift-gatekeeper-system gatekeeper-operator-product
}

snp_label_present() {
	oc get nodes -l amd.feature.node.kubernetes.io/snp=true --no-headers 2>/dev/null | grep -q .
}

runtimeclass_present() {
	[[ "$(oc get runtimeclass kata-cc -o jsonpath='{.handler}' 2>/dev/null)" == "kata-snp" ]]
}

sno_baseline_ok() {
	CATALOGSOURCE="$CATALOGSOURCE" bash "$REPO_ROOT/scripts/validate-sno-baseline.sh" >/tmp/apply-sno-baseline.log 2>&1
}

crd_established() {
	local crd="$1"
	oc wait --for=condition=Established "crd/${crd}" --timeout=10s >/dev/null 2>&1
}

apply_constraint_template_then_instance() {
	local src="$REPO_ROOT/gitops/base/gatekeeper/constraint-coco-mem.yaml"
	local tmpdir template constraint
	tmpdir="$(mktemp -d)"
	template="$tmpdir/template.yaml"
	constraint="$tmpdir/constraint.yaml"
	awk 'BEGIN{doc=0} /^---[[:space:]]*$/ {doc++; next} doc==1 {print}' "$src" > "$template"
	awk 'BEGIN{doc=0} /^---[[:space:]]*$/ {doc++; next} doc==2 {print}' "$src" > "$constraint"
	oc apply -f "$template"
	wait_until "CoCoContainerMemory constraint CRD" crd_established cococontainermemory.constraints.gatekeeper.sh
	oc apply -f "$constraint"
	rm -rf "$tmpdir"
}

need oc
need jq
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

cd "$REPO_ROOT"

log "Pre-apply baseline"
wait_until "SNO baseline" sno_baseline_ok || { cat /tmp/apply-sno-baseline.log >&2; exit 1; }

log "Operator subscriptions"
oc apply -k gitops/base/operators
oc apply -f gitops/base/gatekeeper/operator.yaml
wait_until "operator CSVs Succeeded" all_operator_csvs_succeeded

log "NFD operands and SNP label"
oc apply -k gitops/base/nfd
wait_until "NFD SEV-SNP node label" snp_label_present

log "KataConfig and runtime classes"
oc apply -k gitops/base/kataconfig
wait_until "kata-cc runtime class" runtimeclass_present
wait_until "SNO baseline after KataConfig rollout" sno_baseline_ok || { cat /tmp/apply-sno-baseline.log >&2; exit 1; }

log "Gatekeeper instance and CoCo memory policy"
oc apply -f gitops/base/gatekeeper/gatekeeper-cr.yaml
wait_until "Gatekeeper mutation CRDs" crd_established assign.mutations.gatekeeper.sh
oc apply -f gitops/base/gatekeeper/assign-coco-mem.yaml
apply_constraint_template_then_instance

log "SNO worker install validation"
wait_until "SNO baseline final" sno_baseline_ok || { cat /tmp/apply-sno-baseline.log >&2; exit 1; }
wait_until "kata-cc runtime class final" runtimeclass_present
echo "SNO CoCo worker-side install OK"
echo "Next: make deploy-trustee && make run-rung-a-secret"
