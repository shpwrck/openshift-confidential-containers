#!/usr/bin/env bash
# Staged, idempotent SNO worker-side CoCo install (Phase 4 — `make install-coco-operators`).
#
# Installs the operator stack + confidential runtime on an already-running SNO worker.
# Each stage is gated (waits for a real readiness signal) and is safe to re-run:
#   0. Pre-apply baseline  — node Ready, MCP stable, mirrored CatalogSource READY
#   1. Operators           — NFD, cert-manager, OSC, Trustee, Gatekeeper (wait: CSVs Succeeded)
#   2. NFD + SNP label     — apply NFD operands, wait for the SEV-SNP node label
#   3. KataConfig          — enable CoCo; creates the kata-cc runtime (handler kata-snp); REBOOTS the node
#   4. Gatekeeper policy   — CoCo container-memory floor (mutation + constraint)
#   5. Final validation    — baseline green + kata-cc handler present
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"
SLEEP_SECONDS="${SLEEP_SECONDS:-20}"
CATALOGSOURCE="${CATALOGSOURCE:-cs-redhat-operator-index-v4-20}"

# --- What this installs (single source of truth) -----------------------------
# Operators as "namespace:subscription"; every CSV must reach Succeeded.
readonly OPERATORS=(
	"openshift-nfd:nfd"
	"cert-manager-operator:openshift-cert-manager-operator"
	"openshift-sandboxed-containers-operator:sandboxed-containers-operator"
	"trustee-operator-system:trustee-operator"
	"openshift-gatekeeper-system:gatekeeper-operator-product"
)
readonly SNP_NODE_LABEL="amd.feature.node.kubernetes.io/snp=true"  # NFD sets this on a SEV-SNP node
readonly COCO_RUNTIMECLASS="kata-cc"        # the confidential RuntimeClass workloads request
readonly COCO_RUNTIME_HANDLER="kata-snp"    # what kata-cc resolves to on SEV-SNP (kata-tdx on Intel TDX)

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
	local entry
	for entry in "${OPERATORS[@]}"; do
		# entry is "namespace:subscription"
		subscription_succeeded "${entry%%:*}" "${entry#*:}" || return 1
	done
}

snp_label_present() {
	oc get nodes -l "$SNP_NODE_LABEL" --no-headers 2>/dev/null | grep -q .
}

runtimeclass_present() {
	[[ "$(oc get runtimeclass "$COCO_RUNTIMECLASS" -o jsonpath='{.handler}' 2>/dev/null)" == "$COCO_RUNTIME_HANDLER" ]]
}

sno_baseline_ok() {
	CATALOGSOURCE="$CATALOGSOURCE" bash "$REPO_ROOT/scripts/validate-sno-baseline.sh" >/tmp/apply-sno-baseline.log 2>&1
}

crd_established() {
	local crd="$1"
	oc wait --for=condition=Established "crd/${crd}" --timeout=10s >/dev/null 2>&1
}

# The CoCo memory-floor policy file holds two YAML docs separated by '---':
# a Gatekeeper ConstraintTemplate, then the constraint instance that uses it.
# The instance's kind is a CRD the template generates, so the template must be
# applied AND its CRD Established BEFORE the instance. Split on '---', apply in order.
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

# --- Preconditions -----------------------------------------------------------
need oc
need jq
oc whoami >/dev/null 2>&1 || die "oc is not logged into a cluster"

cd "$REPO_ROOT"

log "Stage 0: pre-apply baseline gate"
wait_until "SNO baseline" sno_baseline_ok || { cat /tmp/apply-sno-baseline.log >&2; exit 1; }

log "Stage 1: install operators (NFD, cert-manager, OSC, Trustee, Gatekeeper)"
oc apply -k gitops/base/operators
oc apply -f gitops/base/gatekeeper/operator.yaml
wait_until "operator CSVs Succeeded" all_operator_csvs_succeeded

log "Stage 2: apply NFD operands; wait for the SEV-SNP node label"
oc apply -k gitops/base/nfd
wait_until "NFD SEV-SNP node label" snp_label_present

log "Stage 3: apply KataConfig (enables CoCo; REBOOTS the node); wait for kata-cc"
oc apply -k gitops/base/kataconfig
wait_until "kata-cc runtime class" runtimeclass_present
wait_until "SNO baseline after KataConfig rollout" sno_baseline_ok || { cat /tmp/apply-sno-baseline.log >&2; exit 1; }

log "Stage 4: Gatekeeper instance + CoCo memory-floor policy"
oc apply -f gitops/base/gatekeeper/gatekeeper-cr.yaml
wait_until "Gatekeeper mutation CRDs" crd_established assign.mutations.gatekeeper.sh
oc apply -f gitops/base/gatekeeper/assign-coco-mem.yaml
apply_constraint_template_then_instance

log "Stage 5: final validation"
wait_until "SNO baseline final" sno_baseline_ok || { cat /tmp/apply-sno-baseline.log >&2; exit 1; }
wait_until "kata-cc runtime class final" runtimeclass_present
echo "SNO CoCo worker-side install OK"
echo "Next: make deploy-trustee && make run-rung-kbs"
