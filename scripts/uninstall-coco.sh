#!/usr/bin/env bash
# Scripted CoCo reset for the disposable rig. The Makefile is the public entrypoint:
#   make uninstall-coco
#   make validate-coco-uninstalled
set -euo pipefail

MODE="${1:-uninstall}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

target_namespaces=(
	trustee-operator-system
	openshift-sandboxed-containers-operator
	openshift-nfd
	cert-manager-operator
	cert-manager
	openshift-gatekeeper-system
)

target_subscriptions=(
	"trustee-operator-system:trustee-operator"
	"openshift-sandboxed-containers-operator:sandboxed-containers-operator"
	"openshift-nfd:nfd"
	"cert-manager-operator:openshift-cert-manager-operator"
	"openshift-gatekeeper-system:gatekeeper-operator-product"
)

csv_regex='^(nfd|sandboxed-containers-operator|trustee-operator|cert-manager-operator|gatekeeper-operator-product)\.'
runtimeclasses=(kata kata-cc kata-nvidia-gpu kata-cc-nvidia-gpu)

log() {
	printf '\n== %s ==\n' "$*"
}

need_cluster() {
	command -v oc >/dev/null || { echo "ERROR: oc is not on PATH" >&2; exit 2; }
	oc whoami >/dev/null 2>&1 || { echo "ERROR: oc is not logged into a cluster" >&2; exit 2; }
}

oc_delete() {
	local resource="$1" name="$2" ns="${3:-}"
	local args=()
	if [[ -n "$ns" ]]; then
		args=(-n "$ns")
	fi

	if oc "${args[@]}" get "$resource" "$name" >/dev/null 2>&1; then
		oc "${args[@]}" delete "$resource" "$name" --ignore-not-found --wait=false || true
	fi
}

delete_kustomize() {
	local path="$1"
	if [[ -f "$path/kustomization.yaml" ]]; then
		oc delete -k "$path" --ignore-not-found --wait=false || true
	fi
}

delete_matching_csvs() {
	if ! command -v jq >/dev/null; then
		echo "WARN: jq not found; deleting only source-namespace CSVs" >&2
		for pair in "${target_subscriptions[@]}"; do
			local ns="${pair%%:*}"
			oc -n "$ns" delete csv --all --ignore-not-found --wait=false || true
		done
		return
	fi

	oc get csv -A -o json 2>/dev/null \
		| jq -r --arg re "$csv_regex" '.items[] | select(.metadata.name | test($re)) | [.metadata.namespace, .metadata.name] | @tsv' \
		| while IFS=$'\t' read -r ns name; do
			[[ -n "$ns" && -n "$name" ]] || continue
			oc -n "$ns" delete csv "$name" --ignore-not-found --wait=false || true
		done
}

delete_olm_objects() {
	for pair in "${target_subscriptions[@]}"; do
		local ns="${pair%%:*}" sub="${pair#*:}"
		oc_delete subscription.operators.coreos.com "$sub" "$ns"
		oc -n "$ns" delete installplan --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
	done
	delete_matching_csvs
}

delete_operator_namespaces() {
	for ns in "${target_namespaces[@]}"; do
		oc delete namespace "$ns" --ignore-not-found --wait=false || true
	done
}

clear_deleting_finalizers() {
	local resource="$1" name="$2" ns="${3:-}"
	local args=()
	if ! command -v jq >/dev/null; then
		echo "WARN: jq not found; skipping stale finalizer check for $resource/$name" >&2
		return
	fi
	if [[ -n "$ns" ]]; then
		args=(-n "$ns")
	fi

	if ! oc "${args[@]}" get "$resource" "$name" >/dev/null 2>&1; then
		return
	fi
	if oc "${args[@]}" get "$resource" "$name" -o json \
		| jq -e '(.metadata.deletionTimestamp != null) and (((.metadata.finalizers // []) | length) > 0)' >/dev/null; then
		echo "Clearing stale finalizers on deleting $resource/$name"
		oc "${args[@]}" patch "$resource" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || true
	fi
}

uninstall() {
	need_cluster
	cd "$REPO_ROOT"

	log "Deleting Trustee and workload operands"
	delete_kustomize gitops/overlays/sno-trustee
	delete_kustomize gitops/base/workloads
	oc_delete kbsconfig.confidentialcontainers.org kbsconfig trustee-operator-system

	log "Deleting Gatekeeper policy operands"
	oc_delete cococontainermemory.constraints.gatekeeper.sh coco-container-memory-floor
	oc_delete constrainttemplate.templates.gatekeeper.sh cococontainermemory
	oc_delete assign.mutations.gatekeeper.sh coco-default-mem-limit
	oc_delete assign.mutations.gatekeeper.sh coco-default-mem-request
	oc_delete gatekeeper.operator.gatekeeper.sh gatekeeper

	log "Deleting KataConfig, NFD operands, and generated runtime artifacts"
	delete_kustomize gitops/base/kataconfig
	oc_delete kataconfig.kataconfiguration.openshift.io cluster-kataconfig
	oc_delete machineconfig 50-enable-sandboxed-containers-extension
	for rc in "${runtimeclasses[@]}"; do
		oc_delete runtimeclass "$rc"
	done
	delete_kustomize gitops/base/nfd
	oc_delete nodefeaturediscovery.nfd.openshift.io nfd-instance openshift-nfd
	oc_delete nodefeaturerule.nfd.k8s-sigs.io amd-sev-snp openshift-nfd

	log "Deleting OLM subscriptions, CSVs, installplans, and stack namespaces"
	delete_olm_objects
	delete_operator_namespaces

	log "Clearing stale finalizers for deleting CoCo custom resources"
	clear_deleting_finalizers kataconfig.kataconfiguration.openshift.io cluster-kataconfig
	clear_deleting_finalizers kbsconfig.confidentialcontainers.org kbsconfig trustee-operator-system
	clear_deleting_finalizers nodefeaturediscovery.nfd.openshift.io nfd-instance openshift-nfd
	clear_deleting_finalizers gatekeeper.operator.gatekeeper.sh gatekeeper
	for rc in "${runtimeclasses[@]}"; do
		clear_deleting_finalizers runtimeclass "$rc"
	done

	log "Uninstall submitted"
	echo "Run 'make validate-coco-uninstalled' until it reports success. On SNO, MachineConfig cleanup may reboot the node."
}

collect_failures() {
	local failures=0
	if ! command -v jq >/dev/null; then
		echo "ERROR: jq is required for validation" >&2
		exit 2
	fi

	local subs
	subs="$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null \
		| jq -r --arg re '^(nfd|openshift-cert-manager-operator|sandboxed-containers-operator|trustee-operator|gatekeeper-operator-product)$' '[.items[] | select(.metadata.name | test($re))] | length')"
	if [[ "$subs" != "0" ]]; then
		echo "FAIL: $subs target Subscription(s) still exist"
		failures=$((failures + 1))
	fi

	local csvs
	csvs="$(oc get csv -A -o json 2>/dev/null \
		| jq -r --arg re "$csv_regex" '[.items[] | select(.metadata.name | test($re))] | length')"
	if [[ "$csvs" != "0" ]]; then
		echo "FAIL: $csvs target CSV(s) still exist"
		failures=$((failures + 1))
	fi

	local operands=0
	local checks=(
		"kataconfig.kataconfiguration.openshift.io cluster-kataconfig"
		"kbsconfig.confidentialcontainers.org kbsconfig -n trustee-operator-system"
		"nodefeaturediscovery.nfd.openshift.io nfd-instance -n openshift-nfd"
		"nodefeaturerule.nfd.k8s-sigs.io amd-sev-snp -n openshift-nfd"
		"gatekeeper.operator.gatekeeper.sh gatekeeper"
		"assign.mutations.gatekeeper.sh coco-default-mem-limit"
		"assign.mutations.gatekeeper.sh coco-default-mem-request"
		"constrainttemplate.templates.gatekeeper.sh cococontainermemory"
		"cococontainermemory.constraints.gatekeeper.sh coco-container-memory-floor"
		"machineconfig 50-enable-sandboxed-containers-extension"
	)
	for check in "${checks[@]}"; do
		if oc get $check >/dev/null 2>&1; then
			echo "FAIL: operand still exists: $check"
			operands=$((operands + 1))
		fi
	done
	if (( operands > 0 )); then
		failures=$((failures + operands))
	fi

	local runtime_count=0
	for rc in "${runtimeclasses[@]}"; do
		if oc get runtimeclass "$rc" >/dev/null 2>&1; then
			echo "FAIL: runtimeclass still exists: $rc"
			runtime_count=$((runtime_count + 1))
		fi
	done
	if (( runtime_count > 0 )); then
		failures=$((failures + runtime_count))
	fi

	local live_ns=0
	for ns in "${target_namespaces[@]}"; do
		if oc get namespace "$ns" >/dev/null 2>&1; then
			local phase
			phase="$(oc get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
			echo "FAIL: namespace still exists: $ns (${phase:-unknown})"
			live_ns=$((live_ns + 1))
		fi
	done
	if (( live_ns > 0 )); then
		failures=$((failures + live_ns))
	fi

	if ! oc wait node --all --for=condition=Ready --timeout=30s >/dev/null 2>&1; then
		echo "FAIL: not all nodes are Ready"
		failures=$((failures + 1))
	fi

	return "$failures"
}

validate_once() {
	need_cluster
	collect_failures
}

validate_wait() {
	need_cluster
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	local last_status=1

	while (( SECONDS < deadline )); do
		if validate_once; then
			echo "CoCo uninstall validation OK"
			return 0
		fi
		last_status=$?
		echo "Waiting ${SLEEP_SECONDS}s for uninstall cleanup to converge..."
		sleep "$SLEEP_SECONDS"
	done

	echo "ERROR: CoCo uninstall validation did not converge within ${WAIT_TIMEOUT}s" >&2
	return "$last_status"
}

case "$MODE" in
	uninstall) uninstall ;;
	validate) validate_wait ;;
	validate-once) validate_once ;;
	*) echo "usage: $0 [uninstall|validate|validate-once]" >&2; exit 2 ;;
esac
