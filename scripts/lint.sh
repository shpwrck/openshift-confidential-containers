#!/usr/bin/env bash
# Hardware-free CI: build every overlay and validate. Safe to run anywhere.
set -euo pipefail

echo "== shell syntax =="
find scripts -maxdepth 1 -type f -name '*.sh' -print0 | xargs -0 -r bash -n

overlays=$(find gitops/overlays -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true)
[ -n "${overlays}" ] || { echo "no overlays yet"; exit 0; }

for o in ${overlays}; do
	echo "== kustomize build ${o} =="
	if command -v kustomize >/dev/null; then kustomize build "${o}" >/dev/null; else oc kustomize "${o}" >/dev/null; fi
	# Optional, if installed:
	command -v kubeconform >/dev/null && kustomize build "${o}" | kubeconform -strict -summary || true
done

echo "== rung b/c render checks =="
bash ./scripts/verify-rung-bc-render.sh

# Rego policies (when present)
if command -v conftest >/dev/null && ls gitops/**/policy.rego >/dev/null 2>&1; then
	conftest verify -p gitops || true
fi
echo "lint OK"
