#!/usr/bin/env bash
# Generate RVPS reference values with Veritas. Hardware-bound: run on the TARGET hardware
# (rig proves the procedure; customer metal regenerates the data). One run per distinct
# hardware config (CPU family + firmware). See docs/notes/enterprise-onboarding-guide.md Step 5.
#
# Usage: TEE=snp ./scripts/gen-rvps-veritas.sh   (TEE=snp|tdx)
set -euo pipefail

TEE="${TEE:-snp}"
TOOLS_IMG="quay.io/openshift_sandboxed_containers/coco-tools:1.12"
PULL_SECRET="${PULL_SECRET:-./pull-secret.json}"
INITDATA="${INITDATA:-./initdata-flavour-b.toml}"
OUT="${OUT:-./rvps-${TEE}.yaml}"

echo "TODO(implement): run Veritas on target hardware —"
echo "  podman run -v ${PULL_SECRET}:/pull-secret.json:ro,z -v ${INITDATA}:/initdata.toml:ro,z \\"
echo "    ${TOOLS_IMG} veritas --platform baremetal --tee ${TEE} \\"
echo "    --authfile /pull-secret.json --initdata /initdata.toml -o ${OUT}"
echo
echo "SNP: one run per distinct socket/hardware config; merge results into the RVPS ConfigMap."
echo "TDX: derive --hw-xfam-allow flags from Trustee logs (xfam is CPU/BIOS-specific) — do not"
echo "     copy from docs."
exit 1
