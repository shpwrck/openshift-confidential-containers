#!/usr/bin/env bash
# Staged worker installation; explicit context and resolved artifact identities required.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/release.sh"
source "$REPO_ROOT/scripts/lib/tee-profile.sh"
source "$REPO_ROOT/scripts/lib/cluster-context.sh"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"
SLEEP_SECONDS="${SLEEP_SECONDS:-20}"
INSTALL_TOPOLOGY="${INSTALL_TOPOLOGY:-customer}"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null || die "$1 is not on PATH"; }
wait_until() {
  local label="$1"; shift
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if "$@"; then echo "PASS: $label"; return 0; fi
    echo "Waiting ${SLEEP_SECONDS}s for $label..."
    sleep "$SLEEP_SECONDS"
  done
  echo "ERROR: timed out waiting for $label" >&2; return 1
}

render_stage() {
  local mode="$1"
  local args=("$mode" --manifest "${RELEASE_MANIFEST:-$REPO_ROOT/install/release-manifest.json}" --tee "$TEE" --topology "$INSTALL_TOPOLOGY")
  [[ "${TRUSTEE_LAB:-0}" != 1 ]] || args+=(--lab)
  python3 "$REPO_ROOT/scripts/lib/worker_install.py" "${args[@]}"
}

manage_subscription() {
  local key="$1" ns="$2" name="$3" expected actual phase plan plan_json args
  expected="$(release_value "operators.${key}.startingCSV")" || die "unresolved CSV for $key"
  actual="$(worker_oc -n "$ns" get subscription "$name" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    phase="$(worker_oc -n "$ns" get csv "$actual" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Succeeded ]] && return 0
  fi
  plan="$(worker_oc -n "$ns" get subscription "$name" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
  [[ -n "$plan" ]] || return 1
  plan_json="$(worker_oc -n "$ns" get installplan "$plan" -o json)" || return 1
  args=(check-plan --manifest "${RELEASE_MANIFEST:-$REPO_ROOT/install/release-manifest.json}" --tee "$TEE" --expected-csv "$expected")
  [[ "${TRUSTEE_LAB:-0}" != 1 ]] || args+=(--lab)
  python3 "$REPO_ROOT/scripts/lib/worker_install.py" "${args[@]}" <<<"$plan_json" || die "refusing InstallPlan $ns/$plan: resolve catalog/CSV mismatch before retrying"
  if [[ "$(jq -r '.spec.approved // false' <<<"$plan_json")" != true ]]; then
    [[ "${APPROVE_INSTALLPLANS:-0}" == 1 ]] || die "pending reviewed InstallPlan $ns/$plan for $expected; inspect it, then explicitly set APPROVE_INSTALLPLANS=1 to allow matching plans"
    worker_oc -n "$ns" patch installplan "$plan" --type=merge -p '{"spec":{"approved":true}}'
  fi
  return 1
}

operators_ready() {
  local entry key ns name ready=0
  for entry in "${OPERATORS[@]}"; do
    IFS=: read -r key ns name <<<"$entry"
    manage_subscription "$key" "$ns" "$name" || ready=1
  done
  return "$ready"
}

tee_nodes_ready() {
  local selector="$COCO_NODE_LABEL"
  if [[ "$INSTALL_TOPOLOGY" == customer ]]; then
    selector+=",${COCO_WORKER_POOL_LABEL}=${COCO_WORKER_POOL_VALUE}"
  fi
  worker_oc get nodes -l "$selector" -o json | jq -e '.items | length > 0' >/dev/null
}
runtime_ready() {
  [[ "$(worker_oc get runtimeclass "$COCO_RUNTIMECLASS" -o jsonpath='{.handler}' 2>/dev/null)" == "$COCO_RUNTIME_HANDLER" ]]
}
kata_ready() {
  local selector="$COCO_NODE_LABEL" pool=master kata nodes mcp runtime
  if [[ "$INSTALL_TOPOLOGY" == customer ]]; then
    selector+=",${COCO_WORKER_POOL_LABEL}=${COCO_WORKER_POOL_VALUE}"
    pool="kata-oc"
  fi
  kata="$(worker_oc get kataconfig cluster-kataconfig -o json)" || return 1
  nodes="$(worker_oc get nodes -l "$selector" -o json)" || return 1
  mcp="$(worker_oc get mcp "$pool" -o json)" || return 1
  runtime="$(worker_oc get runtimeclass "$COCO_RUNTIMECLASS" -o json)" || return 1
  jq -n --argjson kata "$kata" --argjson nodes "$nodes" --argjson mcp "$mcp" --argjson runtime "$runtime" \
    '{kata:$kata,nodes:$nodes,mcp:$mcp,runtime:$runtime}' | \
    python3 "$REPO_ROOT/scripts/lib/worker_install.py" check-kata \
      --manifest "${RELEASE_MANIFEST:-$REPO_ROOT/install/release-manifest.json}" --tee "$TEE" --topology "$INSTALL_TOPOLOGY"
}
baseline_ready() {
  bash "$REPO_ROOT/scripts/validate-sno-baseline.sh" > "$INSTALL_TMP/baseline.log" 2>&1
}
crd_ready() { worker_oc wait --for=condition=Established "crd/$1" --timeout=10s >/dev/null 2>&1; }
apply_memory_policy() {
  render_stage templates < "$REPO_ROOT/gitops/base/gatekeeper/constraint-coco-mem.yaml" > "$INSTALL_TMP/templates.yaml"
  render_stage constraints < "$REPO_ROOT/gitops/base/gatekeeper/constraint-coco-mem.yaml" > "$INSTALL_TMP/constraints.yaml"
  worker_oc apply -f "$INSTALL_TMP/templates.yaml"
  wait_until "memory constraint CRD" crd_ready cococontainermemory.constraints.gatekeeper.sh
  worker_oc apply -f "$INSTALL_TMP/constraints.yaml"
  echo "Memory constraints installed with their declared enforcement modes; unlabeled dryrun is audit-only."
}

main() {
  need python3; need oc; need jq
  load_release_defaults
  load_tee_profile
  load_worker_context
  case "$INSTALL_TOPOLOGY" in
    customer) ;;
    sno) [[ "${TRUSTEE_LAB:-0}" == 1 ]] || die "INSTALL_TOPOLOGY=sno requires explicit TRUSTEE_LAB=1 disposable co-located scope" ;;
    *) die "INSTALL_TOPOLOGY must be customer or sno" ;;
  esac
  require_resolved_release  # Before any cluster mutation or InstallPlan approval.
  if [[ "${TRUSTEE_LAB:-0}" == 1 && -n "${TRUSTEE_CONTEXT:-}" && "$TRUSTEE_CONTEXT" != "$WORKER_CONTEXT" ]]; then
    die "TRUSTEE_LAB=1 requires the same worker/Trustee context"
  fi
  worker_oc whoami >/dev/null || die "not authenticated to WORKER_CONTEXT=$WORKER_CONTEXT"
  if [[ "$INSTALL_TOPOLOGY" == customer ]]; then
    worker_oc get nodes -l "${COCO_WORKER_POOL_LABEL}=${COCO_WORKER_POOL_VALUE}" -o json | jq -e '.items | length > 0' >/dev/null || die "customer deployment requires explicitly selected worker pool ${COCO_WORKER_POOL_LABEL}=${COCO_WORKER_POOL_VALUE}"
  fi
  INSTALL_TMP="$(mktemp -d)"; trap 'rm -rf "$INSTALL_TMP"' EXIT
  OPERATORS=("nfd:openshift-nfd:nfd" "certManager:cert-manager-operator:openshift-cert-manager-operator" "osc:openshift-sandboxed-containers-operator:sandboxed-containers-operator" "gatekeeper:openshift-gatekeeper-system:gatekeeper-operator-product")
  [[ "${TRUSTEE_LAB:-0}" != 1 ]] || OPERATORS+=("trustee:trustee-operator-system:trustee-operator")
  log "Stage 0: selected worker context/version/catalog baseline"
  wait_until baseline baseline_ready || { cat "$INSTALL_TMP/baseline.log" >&2; return 1; }
  log "Stage 1: selected Operators and explicitly reviewed InstallPlans"
  oc kustomize "$REPO_ROOT/gitops/base/operators" | render_stage operators > "$INSTALL_TMP/operators.yaml"
  render_stage operators < "$REPO_ROOT/gitops/base/gatekeeper/operator.yaml" > "$INSTALL_TMP/gatekeeper.yaml"
  worker_oc apply -f "$INSTALL_TMP/operators.yaml"
  worker_oc apply -f "$INSTALL_TMP/gatekeeper.yaml"
  wait_until "expected Operator CSVs Succeeded" operators_ready
  log "Stage 2: NFD and selected TEE eligibility"
  wait_until "NFD instance CRD" crd_ready nodefeaturediscoveries.nfd.openshift.io
  wait_until "NFD rule CRD" crd_ready nodefeaturerules.nfd.openshift.io
  worker_oc apply -k "$REPO_ROOT/$COCO_NFD_PATH"
  wait_until "eligible $TEE nodes" tee_nodes_ready
  log "Stage 3: confidential runtime on selected nodes (rollout may reboot)"
  wait_until "KataConfig CRD" crd_ready kataconfigs.kataconfiguration.openshift.io
  oc kustomize "$REPO_ROOT/gitops/base/kataconfig" | render_stage kata > "$INSTALL_TMP/kata.yaml"
  worker_oc apply -f "$INSTALL_TMP/kata.yaml"
  wait_until "expected confidential runtime handler" runtime_ready
  wait_until "KataConfig and selected nodes have completed the runtime rollout" kata_ready
  wait_until "baseline after runtime rollout" baseline_ready || { cat "$INSTALL_TMP/baseline.log" >&2; return 1; }
  log "Stage 4: memory mutation and all declared constraints"
  worker_oc apply -f "$REPO_ROOT/gitops/base/gatekeeper/gatekeeper-cr.yaml"
  wait_until "Gatekeeper mutation CRD" crd_ready assign.mutations.gatekeeper.sh
  worker_oc apply -f "$REPO_ROOT/gitops/base/gatekeeper/assign-coco-mem.yaml"
  apply_memory_policy
  log "Stage 5: final baseline/runtime verification"
  wait_until baseline baseline_ready || { cat "$INSTALL_TMP/baseline.log" >&2; return 1; }
  wait_until "runtime handler" runtime_ready
  wait_until "KataConfig and selected nodes remain converged" kata_ready
  echo "Worker installation complete; this does not establish attestation or image-policy proof."
  echo "Next: prepare $TEE endorsements, deploy Trustee in its explicit context, then run named proofs."
}
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
