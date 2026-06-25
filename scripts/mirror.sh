#!/usr/bin/env bash
# oc-mirror v2 wrapper for the disconnected SNO mirror (OCP 4.20.18 + OSC 1.12 + Trustee 1.1).
#
# Two modes:
#   mirror     — push the imageset to the bastion mirror registry (the air-gap fill step).
#   resources  — regenerate the cluster resources oc-mirror v2 emits (IDMS/ITMS +
#                CatalogSource). These apply to the cluster POST-INSTALL, not to the
#                installer; they live under the workspace's cluster-resources/ dir.
#
# Usage:
#   MIRROR_REGISTRY=bastion.example.com:8443 ./scripts/mirror.sh mirror
#   MIRROR_REGISTRY=bastion.example.com:8443 ./scripts/mirror.sh resources
#
# Requires: oc-mirror on PATH (or ./bin from scripts/install-tools.sh) and a pull/push auth
# for the mirror registry in ${REGISTRY_AUTH_FILE:-~/.config/containers/auth.json} (or the
# legacy ~/.docker/config.json). The node firewall lets ONLY the node reach the bastion;
# this script runs on the bastion/admin host that can push to it.
set -euo pipefail

CONFIG="install/imageset-config.yaml"
WORKSPACE="${WORKSPACE:-file://./mirror}"   # oc-mirror v2 workspace (cache + generated resources)
MODE="${1:-mirror}"

: "${MIRROR_REGISTRY:?set MIRROR_REGISTRY=<host:port> of the bastion mirror registry}"

OCM="oc-mirror"
[ -x "./bin/oc-mirror" ] && OCM="./bin/oc-mirror"

case "${MODE}" in
  mirror)
    # m2m/mirror-to-mirror disconnected push. v2 derives the destination repo layout itself.
    exec "${OCM}" --v2 \
      -c "${CONFIG}" \
      --workspace "${WORKSPACE}" \
      "docker://${MIRROR_REGISTRY}"
    ;;

  resources)
    # After a mirror run, oc-mirror v2 writes IDMS/ITMS + CatalogSource YAML under:
    #   ./mirror/working-dir/cluster-resources/
    # (idms-oc-mirror.yaml, itms-oc-mirror.yaml, cs-*.yaml). Apply these to the LIVE cluster
    # AFTER install completes (the installer uses install-config's imageDigestSources instead).
    RES_DIR="./mirror/working-dir/cluster-resources"
    if [ -d "${RES_DIR}" ]; then
      echo "oc-mirror v2 cluster resources (apply POST-INSTALL with 'oc apply -f'):"
      ls -1 "${RES_DIR}"
      echo
      echo "Post-install:  oc apply -f ${RES_DIR}/"
    else
      echo "No cluster-resources dir yet at ${RES_DIR}."
      echo "Run './scripts/mirror.sh mirror' first; v2 emits them during the mirror run."
      exit 1
    fi
    ;;

  *)
    echo "usage: MIRROR_REGISTRY=<host:port> $0 {mirror|resources}" >&2
    exit 2
    ;;
esac
