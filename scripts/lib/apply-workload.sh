#!/usr/bin/env bash
# Shared execution path; rendering is deliberately independent of cluster credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$ROOT/scripts/lib/release.sh"
# shellcheck source=scripts/lib/tee-profile.sh
source "$ROOT/scripts/lib/tee-profile.sh"
# shellcheck source=scripts/lib/cluster-context.sh
source "$ROOT/scripts/lib/cluster-context.sh"
load_release_defaults
load_tee_profile
if [[ "${RENDER_ONLY:-0}" == 1 || "${EMIT_INITDATA:-0}" == 1 ]]; then
  exec python3 "$ROOT/scripts/render-workload.py" "$RUNG"
fi
require_resolved_release
load_cluster_contexts
if [[ "$RUNG" == encrypted && "${EXPERIMENTAL_ENCRYPTED_IMAGES:-0}" != 1 ]]; then
  echo 'ERROR: encrypted pulls need EXPERIMENTAL_ENCRYPTED_IMAGES=1 on a disposable candidate rig.' >&2
  exit 2
fi
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
python3 "$ROOT/scripts/render-workload.py" "$RUNG" > "$tmpdir/pod.yaml"
NS="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["metadata"]["namespace"])' "$tmpdir/pod.yaml")"
POD_NAME="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["metadata"]["name"])' "$tmpdir/pod.yaml")"
handler="$(worker_oc get runtimeclass "$COCO_RUNTIMECLASS" -o jsonpath='{.handler}')"
[[ "$handler" == "$COCO_RUNTIME_HANDLER" ]] || { echo "ERROR: expected $COCO_RUNTIME_HANDLER, found $handler" >&2; exit 2; }
trustee_oc -n "${TRUSTEE_NS:-trustee-operator-system}" rollout status deployment/trustee-deployment --timeout=180s
# Create fails on a name collision, preserving any prior/customer pod for inspection.
worker_oc create -f "$tmpdir/pod.yaml"
worker_oc -n "$NS" wait "pod/$POD_NAME" --for=condition=Ready --timeout="${WAIT_TIMEOUT:-900}s"
echo "Workload $NS/$POD_NAME is Ready. Use make test-rung for an allow/deny/recovery proof."
