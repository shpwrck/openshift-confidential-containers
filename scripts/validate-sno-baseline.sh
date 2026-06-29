#!/usr/bin/env bash
# Read-only pre-apply gate for the SNO rig.
set -euo pipefail

CATALOGSOURCE="${CATALOGSOURCE:-cs-redhat-operator-index-v4-20}"
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
oc whoami >/dev/null 2>&1 || { echo "ERROR: oc is not logged into a cluster" >&2; exit 2; }

if oc wait node --all --for=condition=Ready --timeout=30s >/dev/null 2>&1; then
	ok "all nodes Ready"
else
	bad "not all nodes are Ready"
	oc get nodes || true
fi

mcp_json="$(oc get mcp -o json)"
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

catalog_state="$(oc -n "$CATALOGSOURCE_NS" get catalogsource "$CATALOGSOURCE" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
if [[ "$catalog_state" == "READY" ]]; then
	ok "CatalogSource ${CATALOGSOURCE_NS}/${CATALOGSOURCE} READY"
else
	bad "CatalogSource ${CATALOGSOURCE_NS}/${CATALOGSOURCE} not READY (state=${catalog_state:-missing})"
fi

if (( fail == 0 )); then
	echo "SNO baseline validation OK"
else
	echo "SNO baseline validation failed"
	exit 1
fi
