#!/usr/bin/env bash
# Air-gap VCEK collection for the Trustee OfflineStore (the customer sign-off gate).
# Generation-agnostic (dodges trustee bug #591 'Milan' hardcode). Re-runnable so it also
# serves the TCB-refresh case after a firmware update.
#
# DESIGN (see docs/design/engagement-design.md §4):
#   per socket:  snphost show vcek-url  -> hwid + KDS URL
#   connected:   download <url> -> vcek.der            (run where KDS is reachable)
#   air-gapped:  one K8s secret per LOWERCASE hwid, mounted via KbsConfig.kbsLocalCertCacheSpec
#                at /opt/confidential-containers/attestation-service/kds-store/vcek/<hwid>/vcek.der
#
# Usage: ./scripts/collect-vcek.sh <node-name> [namespace]
set -euo pipefail

NODE="${1:?usage: collect-vcek.sh <node-name> [namespace]}"
NS="${2:-trustee-operator-system}"
OUT="${OUT:-./vcek-bundle}"
TOOLS_IMG="quay.io/openshift_sandboxed_containers/coco-tools:1.12"

mkdir -p "${OUT}"

echo "TODO(implement): per-socket loop —"
echo "  1. VCEK_URL=\$(oc debug node/${NODE} -- chroot /host podman run --rm --privileged ${TOOLS_IMG} \\"
echo "                  /tools/snphost show vcek-url --socket <n> | grep -o 'https://.*')"
echo "  2. HWID=\$(echo \"\$VCEK_URL\" | sed -E 's#.*/v1/[^/]+/([^?]+).*#\\1#' | tr 'A-Z' 'a-z')  # LOWERCASE"
echo "  3. (connected host) curl -fsSL \"\$VCEK_URL\" -o ${OUT}/\$HWID/vcek.der"
echo "  4. oc create secret generic vcek-\$HWID --from-file=vcek.der=${OUT}/\$HWID/vcek.der -n ${NS}"
echo "  5. patch KbsConfig.kbsLocalCertCacheSpec.secrets[] with mountPath .../kds-store/vcek/\$HWID"
echo
echo "Landmines: HWID must be lowercase (else silent KDS fallthrough); collect one VCEK per"
echo "socket per node; verify the .der carries ARK/ASK chain or supply them separately."
exit 1
