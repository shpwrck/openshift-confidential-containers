#!/usr/bin/env bash
# make reset-lab: put the disposable lab back to plain OpenShift in one command.
# It shows the cluster and what goes, asks once, marks the lab's namespaces as
# disposable, removes the CoCo stack, waits until it is gone and checks the
# cluster again. OpenShift, the mirror, the servers and COCO_STATE_DIR stay.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/cluster-context.sh"
DISPOSABLE_LABEL='coco.openshift.io/disposable'

die() { echo "ERROR: $*" >&2; exit 2; }

# The lab settings come from make connect's lab.env; a shared cluster has neither.
[[ "${TRUSTEE_LAB:-0}" == 1 ]] || die "reset-lab is only for the disposable lab: run make connect, then source scripts/env.sh (it sets TRUSTEE_LAB=1)"
[[ -n "${WORKER_CONTEXT:-}" && "${TRUSTEE_CONTEXT:-}" == "$WORKER_CONTEXT" ]] || die "reset-lab needs identical WORKER_CONTEXT and TRUSTEE_CONTEXT, as lab.env sets them"
command -v oc >/dev/null || die "oc not on PATH"
command -v jq >/dev/null || die "jq not on PATH"
load_worker_context
namespaces=()  # Bash 3.2 (macOS) has no mapfile.
while IFS= read -r ns; do namespaces+=("$ns"); done < <(bash "$REPO_ROOT/scripts/uninstall-coco.sh" namespaces)
(( ${#namespaces[@]} > 0 )) || die "uninstall-coco.sh listed no namespaces"

server="$(worker_oc whoami --show-server)" || die "cannot reach WORKER_CONTEXT=$WORKER_CONTEXT; run make connect again"
echo "This removes the CoCo Operators, Trustee, the test workloads and the Kata runtime"
echo "from context $WORKER_CONTEXT, API $server:"
echo
worker_oc get nodes
echo
existing=()
for ns in "${namespaces[@]}"; do
  object="$(worker_oc get namespaces "$ns" --ignore-not-found -o json)" || die "cannot inspect namespace $ns"
  if [[ -n "$object" ]]; then
    existing+=("$ns")
    echo "  delete namespace $ns"
  fi
done
(( ${#existing[@]} > 0 )) || die "none of the lab namespaces exist, so there is nothing to reset"
echo
echo "The node reboots once while the runtime is removed. OpenShift, the mirror,"
echo "the servers and ${COCO_STATE_DIR:-the state directory} stay."
echo
if [[ "${ALLOW_DISPOSABLE_UNINSTALL:-0}" != 1 ]]; then
  [[ -t 0 ]] || die "without a terminal, set ALLOW_DISPOSABLE_UNINSTALL=1 to reset"
  read -r -p "Type reset to remove them: " answer
  [[ "$answer" == reset ]] || die "nothing was changed"
fi

# The uninstall only touches namespaces carrying the label.
for ns in "${existing[@]}"; do
  object="$(worker_oc get namespaces "$ns" --ignore-not-found -o json)" || die "cannot inspect namespace $ns"
  [[ -n "$object" ]] || continue
  if ! jq -e --arg scope_label "$DISPOSABLE_LABEL" '.metadata.labels[$scope_label] == "true"' <<<"$object" >/dev/null; then
    worker_oc label namespace "$ns" "$DISPOSABLE_LABEL=true" >/dev/null
  fi
done
ALLOW_DISPOSABLE_UNINSTALL=1 SHOW_NEXT=0 bash "$REPO_ROOT/scripts/uninstall-coco.sh"
echo
echo "== Waiting until everything is gone =="
bash "$REPO_ROOT/scripts/uninstall-coco.sh" validate
echo
echo "== Checking the cluster =="
BASELINE_WAIT="${BASELINE_WAIT:-900}" bash "$REPO_ROOT/scripts/validate-sno-baseline.sh"
echo
echo "Reset complete. Install again with: make install-coco-operators"
