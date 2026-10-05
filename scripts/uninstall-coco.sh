#!/usr/bin/env bash
# Explicit disposable, co-located lab reset. Validation modes are read-only.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/cluster-context.sh"
MODE="${1:-uninstall}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
WORKLOAD_NS="${WORKLOAD_NS:-coco-validation}"
TRUSTEE_NS="${TRUSTEE_NS:-${NS:-trustee-operator-system}}"
TRUSTEE_NAME="${TRUSTEE_NAME:-trustee-config}"
DISPOSABLE_LABEL='coco.openshift.io/disposable'
target_namespaces=("$TRUSTEE_NS" openshift-sandboxed-containers-operator openshift-nfd cert-manager-operator cert-manager openshift-gatekeeper-system)
legacy_pods=(rung-a rung-a-secret rung-encrypted rung-signed negtest-rung-a negtest-rung-rvps negtest-rung-rvps-ctrl negtest-rung-encrypted negtest-rung-signed negtest-air-gap rung-b-signed rung-c-encrypted negtest-rung-b negtest-rung-c)
operands=(
  "trusteeconfigs.confidentialcontainers.org|$TRUSTEE_NAME|$TRUSTEE_NS"
  "cococontainermemory.constraints.gatekeeper.sh|coco-container-memory-floor|"
  "cococontainermemory.constraints.gatekeeper.sh|coco-container-memory-floor-unlabeled|"
  "constrainttemplates.templates.gatekeeper.sh|cococontainermemory|"
  "assign.mutations.gatekeeper.sh|coco-default-mem-limit|"
  "assign.mutations.gatekeeper.sh|coco-default-mem-request|"
  "gatekeepers.operator.gatekeeper.sh|gatekeeper|"
  "kataconfigs.kataconfiguration.openshift.io|cluster-kataconfig|"
  "nodefeaturediscoveries.nfd.openshift.io|nfd-instance|openshift-nfd"
  "nodefeaturerules.nfd.openshift.io|amd-sev-snp|openshift-nfd"
  "machineconfigs.machineconfiguration.openshift.io|50-enable-sandboxed-containers-extension|"
  "runtimeclasses.node.k8s.io|kata-cc|"
  "runtimeclasses.node.k8s.io|kata|")

die() { echo "ERROR: $*" >&2; exit 2; }
known_resource() { grep -Fxq "$1" <<<"$API_RESOURCES"; }
resource_oc() {
  local ns="$1"; shift
  # Bash 3.2 treats an empty array expansion as unset under nounset. Branch on
  # the optional namespace instead, keeping each command argument intact.
  if [[ -n "$ns" ]]; then
    worker_oc -n "$ns" "$@"
  else
    worker_oc "$@"
  fi
}
get_object() {
  local kind="$1" name="$2" ns="${3:-}"
  known_resource "$kind" || return 0
  resource_oc "$ns" get "$kind" "$name" --ignore-not-found -o json
}

check_disposable_scope() {
  [[ "${TRUSTEE_LAB:-0}" == 1 && "${ALLOW_DISPOSABLE_UNINSTALL:-0}" == 1 ]] || die "uninstall requires TRUSTEE_LAB=1 and ALLOW_DISPOSABLE_UNINSTALL=1"
  [[ -n "${TRUSTEE_CONTEXT:-}" && "$TRUSTEE_CONTEXT" == "$WORKER_CONTEXT" ]] || die "uninstall requires explicit identical WORKER_CONTEXT and TRUSTEE_CONTEXT"
  local ns object count=0
  # Check every existing target before the first deletion, not as each is deleted.
  for ns in "${target_namespaces[@]}" "$WORKLOAD_NS"; do
    object="$(get_object namespaces "$ns")" || die "cannot inspect namespace $ns"
    [[ -n "$object" ]] || continue
    jq -e --arg label "$DISPOSABLE_LABEL" '.metadata.labels[$label] == "true"' <<<"$object" >/dev/null || die "namespace $ns lacks $DISPOSABLE_LABEL=true; refusing shared-resource teardown"
    count=$((count+1))
  done
  (( count > 0 )) || die "no labeled disposable namespace exists to establish reset scope"
}

delete_object() {
  local kind="$1" name="$2" ns="${3:-}" object
  object="$(get_object "$kind" "$name" "$ns")" || die "failed to inspect $kind/$name"
  [[ -n "$object" ]] || return 0
  resource_oc "$ns" delete "$kind" "$name" --ignore-not-found --wait=false
  if [[ "${FORCE_FINALIZERS:-0}" == 1 ]]; then
    object="$(get_object "$kind" "$name" "$ns")" || die "failed to inspect deletion state"
    if [[ -n "$object" ]] && jq -e '.metadata.deletionTimestamp != null and (.metadata.finalizers // [] | length) > 0' <<<"$object" >/dev/null; then
      echo "FORCE_FINALIZERS=1: explicitly removing finalizers on deleting $kind/$name"
      resource_oc "$ns" patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}'
    fi
  fi
  # Keep the owning controller installed until its operands finish deletion.
  resource_oc "$ns" wait --for=delete "$kind/$name" --timeout="${WAIT_TIMEOUT}s" || die "$kind/$name still exists; controllers retained. Inspect finalizers before any explicit FORCE_FINALIZERS=1 retry."
}

workload_names() {
  local ns_object pods
  ns_object="$(get_object namespaces "$WORKLOAD_NS")" || return
  [[ -n "$ns_object" ]] || return 0
  pods="$(worker_oc -n "$WORKLOAD_NS" get pods -o json)" || return
  printf '%s' "$pods" | jq -r --argjson legacy "$(printf '%s\n' "${legacy_pods[@]}" | jq -R . | jq -s .)" '.items[] | select(.metadata.labels["coco.openshift.io/proof-run"] != null or (.metadata.name as $n | $legacy | index($n))) | .metadata.name'
}

uninstall() {
  check_disposable_scope
  local name kind ns entry names kbs_names="" object
  names="$(workload_names)" || die "failed to inspect proof workloads"
  while IFS= read -r name; do
    [[ -z "$name" ]] || delete_object pods "$name" "$WORKLOAD_NS"
  done <<<"$names"
  # Discover owned/generated KbsConfig names before deleting their TrusteeConfig.
  if known_resource kbsconfigs.confidentialcontainers.org; then
    kbs_names="$(worker_oc -n "$TRUSTEE_NS" get kbsconfigs -o json --ignore-not-found | jq -r '.items[]?.metadata.name')" || die "failed to inspect lab KbsConfigs"
  fi
  # Stop reconciliation before removing any generated KbsConfig. Retain the
  # operator until both its top-level and generated operands have finalized.
  delete_object trusteeconfigs.confidentialcontainers.org "$TRUSTEE_NAME" "$TRUSTEE_NS"
  if [[ -n "$kbs_names" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] || delete_object kbsconfigs.confidentialcontainers.org "$name" "$TRUSTEE_NS"
    done <<<"$kbs_names"
  fi
  for entry in "${operands[@]}"; do
    IFS='|' read -r kind name ns <<<"$entry"
    delete_object "$kind" "$name" "$ns"
  done
  for ns in "${target_namespaces[@]}"; do
    object="$(get_object namespaces "$ns")" || die "failed to inspect namespace $ns"
    [[ -n "$object" ]] || continue
    # All these namespaces passed the explicit disposable label guard above.
    worker_oc -n "$ns" delete subscriptions.operators.coreos.com --all --ignore-not-found --wait=false
    worker_oc -n "$ns" delete installplans.operators.coreos.com --all --ignore-not-found --wait=false
    worker_oc -n "$ns" delete clusterserviceversions.operators.coreos.com --all --ignore-not-found --wait=false
    worker_oc delete namespace "$ns" --ignore-not-found --wait=false
  done
  echo "Disposable stack deletion requested. Controllers finalized operands before namespace deletion."
  echo "Run validate-coco-uninstalled for convergence; no finalizers are cleared unless FORCE_FINALIZERS=1."
}

validate_once() {
  local failures=0 entry kind name ns object names
  for entry in "${operands[@]}"; do
    IFS='|' read -r kind name ns <<<"$entry"
    object="$(get_object "$kind" "$name" "$ns")" || return 1
    if [[ -n "$object" ]]; then echo "FAIL: operand still exists: $kind/$name"; failures=1; fi
  done
  for ns in "${target_namespaces[@]}"; do
    object="$(get_object namespaces "$ns")" || return 1
    if [[ -n "$object" ]]; then echo "FAIL: namespace still exists: $ns"; failures=1; fi
  done
  names="$(workload_names)" || return 1
  if [[ -n "$names" ]]; then echo "FAIL: proof/legacy workload pods still exist: $names"; failures=1; fi
  worker_oc wait node --all --for=condition=Ready --timeout=30s >/dev/null 2>&1 || failures=1
  return "$failures"
}

command -v oc >/dev/null || die "oc not on PATH"
command -v jq >/dev/null || die "jq not on PATH"
load_worker_context
# Reject missing destructive-mode intent before even reading the cluster.
if [[ "$MODE" == uninstall ]]; then
  [[ "${TRUSTEE_LAB:-0}" == 1 && "${ALLOW_DISPOSABLE_UNINSTALL:-0}" == 1 ]] || die "uninstall requires TRUSTEE_LAB=1 and ALLOW_DISPOSABLE_UNINSTALL=1"
  [[ -n "${TRUSTEE_CONTEXT:-}" && "$TRUSTEE_CONTEXT" == "$WORKER_CONTEXT" ]] || die "set identical explicit WORKER_CONTEXT and TRUSTEE_CONTEXT for the disposable lab"
fi
worker_oc whoami >/dev/null || die "selected worker context is unavailable"
API_RESOURCES="$(worker_oc api-resources -o name)" || die "cannot discover cluster APIs"
case "$MODE" in
  uninstall) uninstall ;;
  validate-once) validate_once ;;
  validate)
    deadline=$((SECONDS + WAIT_TIMEOUT))
    while (( SECONDS < deadline )); do
      if validate_once; then echo "CoCo uninstall validation OK"; exit 0; fi
      sleep "$SLEEP_SECONDS"
    done
    die "uninstall did not converge within ${WAIT_TIMEOUT}s"
    ;;
  *) die "usage: uninstall-coco.sh [uninstall|validate|validate-once]" ;;
esac
