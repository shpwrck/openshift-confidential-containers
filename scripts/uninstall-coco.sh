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

# Imperatively-applied workload pods (rung happy + negative pods) — NOT in any kustomization, so
# delete_kustomize never sweeps them; they must be deleted by name (see apply-rung-*.sh and
# negative-test.sh). They live in WORKLOAD_NS (default `default`), bound to the kata-cc runtimeclass.
# Includes the LEGACY pre-rename names (rung-b-signed/rung-c-encrypted/negtest-rung-{b,c}): a rig that
# ran the proofs before the #19/#20 capability rename still has those pods, and nothing else sweeps
# them, so uninstall must clean both the new and the old names (harmless when absent — --ignore-not-found).
WORKLOAD_NS="${WORKLOAD_NS:-default}"
workload_pods=(rung-a rung-a-secret rung-encrypted rung-signed negtest-rung-a negtest-rung-encrypted negtest-rung-signed negtest-air-gap \
  rung-b-signed rung-c-encrypted negtest-rung-b negtest-rung-c)

log() {
	printf '\n== %s ==\n' "$*"
}

need_tools() {
	command -v oc >/dev/null || { echo "ERROR: oc is not on PATH" >&2; exit 2; }
	# jq is load-bearing for CSV cleanup, the finalizer sweep, and validation — require it up
	# front so uninstall does not silently degrade to a best-effort no-op on a minimal box.
	command -v jq >/dev/null || { echo "ERROR: jq is required (CSV cleanup, finalizer sweep, and validation all need it)" >&2; exit 2; }
}

need_cluster() {
	need_tools
	oc whoami >/dev/null 2>&1 || { echo "ERROR: oc is not logged into a cluster" >&2; exit 2; }
}

# Wait for the API server to become reachable, bounded by WAIT_TIMEOUT. The uninstall removes the
# kata MachineConfig, which reboots the single node, so a validate run chained immediately after
# (e.g. `make uninstall-coco && make validate-coco-uninstalled`) must ride out the API-down reboot
# window rather than failing fast the way a one-shot `oc whoami` would.
wait_for_api() {
	local deadline=$((SECONDS + WAIT_TIMEOUT))
	while (( SECONDS < deadline )); do
		# Bound each probe: a blackholed API (accepts the connection but never answers) during the
		# reboot would otherwise hang a single `oc whoami` indefinitely, defeating WAIT_TIMEOUT.
		oc whoami --request-timeout=5s >/dev/null 2>&1 && return 0
		echo "Waiting ${SLEEP_SECONDS}s for cluster API to become reachable (node may be rebooting)..."
		sleep "$SLEEP_SECONDS"
	done
	echo "ERROR: cluster API not reachable within ${WAIT_TIMEOUT}s" >&2
	return 1
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

	# Teardown order is load-bearing: workload pods -> Trustee/Gatekeeper/Kata/NFD operands ->
	# OLM subs/CSVs + namespaces -> force-clear finalizers (retried). Operands go before operators
	# so the owning controllers can still run their own finalizers; the finalizer sweep at the end
	# is the last-resort cleanup for anything left Terminating once its operator is gone.
	log "Deleting imperatively-applied workload pods (rung happy + negative)"
	oc -n "$WORKLOAD_NS" delete pod "${workload_pods[@]}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

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

	log "Clearing stale finalizers for deleting CoCo custom resources (retry until gone)"
	# The operators that own these finalizers were just deleted, so anything still Terminating can
	# never be reconciled — force-clear it. This MUST retry, not fire once: the deletionTimestamp
	# may not be set the instant we look, a dying operator can re-add a finalizer, and on SNO the
	# API is briefly unreachable while removing the kata MachineConfig reboots the node. We only
	# conclude "done" from a SUCCESSFUL query showing the targets are gone — never from an
	# API-down error (which would otherwise break the loop early mid-reboot and re-strand kata-cc).
	local fz_deadline=$((SECONDS + WAIT_TIMEOUT)) remaining rc
	while (( SECONDS < fz_deadline )); do
		clear_deleting_finalizers kataconfig.kataconfiguration.openshift.io cluster-kataconfig
		clear_deleting_finalizers kbsconfig.confidentialcontainers.org kbsconfig trustee-operator-system
		clear_deleting_finalizers nodefeaturediscovery.nfd.openshift.io nfd-instance openshift-nfd
		clear_deleting_finalizers gatekeeper.operator.gatekeeper.sh gatekeeper
		for rc in "${runtimeclasses[@]}"; do
			clear_deleting_finalizers runtimeclass "$rc"
		done
		if oc get nodes >/dev/null 2>&1; then
			remaining=0
			for rc in "${runtimeclasses[@]}"; do
				oc get runtimeclass "$rc" >/dev/null 2>&1 && remaining=$((remaining + 1))
			done
			oc get kataconfig.kataconfiguration.openshift.io cluster-kataconfig >/dev/null 2>&1 && remaining=$((remaining + 1))
			(( remaining == 0 )) && break
		fi
		sleep "$SLEEP_SECONDS"
	done

	log "Uninstall complete (operands, operators, namespaces deleted; finalizers cleared)"
	echo "On SNO, removing the kata MachineConfig reboots the node; this step waited for the"
	echo "Terminating CoCo resources to clear. Run 'make validate-coco-uninstalled' to confirm"
	echo "the node is Ready and nothing remains."
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
		# shellcheck disable=SC2086  # $check is a multi-arg oc-get spec (kind name [-n ns]); word-splitting is intentional
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

	local live_pods=0 p
	for p in "${workload_pods[@]}"; do
		if oc -n "$WORKLOAD_NS" get pod "$p" >/dev/null 2>&1; then
			echo "FAIL: workload pod still exists: $WORKLOAD_NS/$p"
			live_pods=$((live_pods + 1))
		fi
	done
	if (( live_pods > 0 )); then
		failures=$((failures + live_pods))
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
	need_tools
	# The paired uninstall reboots the SNO node; wait out the API-down window before validating,
	# then use collect_failures directly (not validate_once) so a transient API blip mid-loop
	# counts as "not converged yet" and retries, instead of exiting via need_cluster.
	wait_for_api || return 1
	local deadline=$((SECONDS + WAIT_TIMEOUT))

	while (( SECONDS < deadline )); do
		if collect_failures; then
			echo "CoCo uninstall validation OK"
			return 0
		fi
		echo "Waiting ${SLEEP_SECONDS}s for uninstall cleanup to converge..."
		sleep "$SLEEP_SECONDS"
	done

	# Timeout is by definition non-convergence = failure. (The previous `last_status=$?` captured
	# the if-statement's status, which is 0 when validate_once fails with no else branch — so this
	# used to return 0 and falsely report success.)
	echo "ERROR: CoCo uninstall validation did not converge within ${WAIT_TIMEOUT}s" >&2
	return 1
}

case "$MODE" in
	uninstall) uninstall ;;
	validate) validate_wait ;;
	validate-once) validate_once ;;
	*) echo "usage: $0 [uninstall|validate|validate-once]" >&2; exit 2 ;;
esac
