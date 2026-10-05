#!/usr/bin/env bash
# Read-only pre-apply gate for the SNO rig.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/release.sh"
source "$REPO_ROOT/scripts/lib/tee-profile.sh"
source "$REPO_ROOT/scripts/lib/cluster-context.sh"
load_release_defaults
load_tee_profile
load_worker_context
CATALOGSOURCE_NS="${CATALOGSOURCE_NS:-openshift-marketplace}"
fail=0

need() {
	command -v "$1" >/dev/null || { echo "ERROR: $1 is not on PATH" >&2; exit 2; }
}

bad() {
	echo "FAIL: $*"
	fail=1
}

ok() {
	echo "PASS: $*"
}

need oc
need jq
worker_oc whoami >/dev/null 2>&1 || { echo "ERROR: oc is not logged into a cluster" >&2; exit 2; }

version_json="$(worker_oc get clusterversion version -o json)"
actual_version="$(jq -r '.status.desired.version // empty' <<<"$version_json")"
actual_image="$(jq -r '.status.desired.image // empty' <<<"$version_json")"
if [[ "$actual_version" == "$OCP_VERSION" && "${actual_image##*@}" == "${OCP_RELEASE_IMAGE##*@}" ]]; then
  ok "desired OCP payload matches selected release $OCP_VERSION"
else
  bad "OCP payload mismatch: expected $OCP_VERSION / ${OCP_RELEASE_IMAGE##*@}; observed $actual_version / ${actual_image##*@}"
fi

# The desired payload is set at upgrade start. Require the newest history item
# and healthy CVO conditions so an in-progress/failed upgrade cannot pass.
if jq -e --arg version "$OCP_VERSION" --arg digest "${OCP_RELEASE_IMAGE##*@}" '
  .status as $status
  | ($status.history[0] // {}) as $latest
  | $latest.state == "Completed"
    and $latest.version == $version
    and (($latest.image // "" | split("@") | last) == $digest)
    and ($latest.completionTime != null)
    and any($status.conditions[]?; .type == "Available" and .status == "True")
    and any($status.conditions[]?; .type == "Progressing" and .status == "False")
    and any($status.conditions[]?; .type == "Failing" and .status == "False")
' <<<"$version_json" >/dev/null; then
  ok "selected OCP rollout completed; CVO Available, not Progressing or Failing"
else
  bad "selected OCP rollout is incomplete or CVO conditions are unhealthy/missing"
fi

if worker_oc wait node --all --for=condition=Ready --timeout=30s >/dev/null 2>&1; then
	ok "all nodes Ready"
else
	bad "not all nodes are Ready"
	worker_oc get nodes || true
fi

mcp_json="$(worker_oc get mcp -o json)"
mcp_failures="$(printf '%s' "$mcp_json" | jq -r '
  .items[]
  | select(.status.machineCount > 0)
  | . as $mcp
  | {
      name: .metadata.name,
      updated: ([.status.conditions[]? | select(.type == "Updated") | .status][0] // "False"),
      updating: ([.status.conditions[]? | select(.type == "Updating") | .status][0] // "True"),
      degraded: ([.status.conditions[]? | select(.type == "Degraded") | .status][0] // "True"),
      message: ([.status.conditions[]? | select(.type == "Degraded") | .message][0] // "")
    }
  | select(.updated != "True" or .updating != "False" or .degraded != "False")
  | "\(.name)\tUpdated=\(.updated)\tUpdating=\(.updating)\tDegraded=\(.degraded)\t\(.message)"
')"
if [[ -n "$mcp_failures" ]]; then
	bad "MachineConfigPool is not stable"
	printf '%s\n' "$mcp_failures" | sed 's/^/  /'
else
	ok "MachineConfigPools stable"
fi

catalogs=("$CATALOGSOURCE")
for catalog in "${catalogs[@]}"; do
  catalog_state="$(worker_oc -n "$CATALOGSOURCE_NS" get catalogsource "$catalog" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
  if [[ "$catalog_state" == READY ]]; then
    ok "CatalogSource ${CATALOGSOURCE_NS}/${catalog} READY"
  else
    bad "CatalogSource ${CATALOGSOURCE_NS}/${catalog} not READY (state=${catalog_state:-missing})"
  fi
done

if (( fail == 0 )); then
	echo "SNO baseline validation OK"
else
	echo "SNO baseline validation failed"
	exit 1
fi
