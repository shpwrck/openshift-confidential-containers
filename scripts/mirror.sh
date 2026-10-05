#!/usr/bin/env bash
# oc-mirror v2 wrapper for the disconnected mirror selected by the release manifest.
#
# Two modes:
#   mirror     — push the imageset to the bastion mirror registry (the air-gap fill step).
#   resources  — regenerate the cluster resources oc-mirror v2 emits (IDMS/ITMS +
#                CatalogSource). These apply to the cluster POST-INSTALL, not to the
#                installer; they live under the workspace's cluster-resources/ dir.
#
# Usage:
#   ARTIFACTORY_REGISTRY=bastion.example.com:8443 ./scripts/mirror.sh mirror      # MIRROR_REGISTRY still honored
#   ARTIFACTORY_REGISTRY=bastion.example.com:8443 ./scripts/mirror.sh resources
#
# Requires: oc-mirror on PATH (or ./bin from scripts/install-tools.sh) and a MERGED auth
# (Red Hat pull secret + the mirror registry's push cred) in ~/.docker/config.json.
#
# DO NOT set REGISTRY_AUTH_FILE: oc-mirror v2 embeds a `distribution` registry that consumes
# ALL `REGISTRY_*` env vars as its own config, so REGISTRY_AUTH_FILE collides and panics
# ("StorageDriver not registered"). We unset it defensively below and rely on the default
# ~/.docker/config.json lookup. (Learned on metal 2026-06-26.) On a RHEL-family bastion, prefer
# the `oc-mirror.rhel9.tar.gz` build (no libgpgme dependency).
#
# The node firewall lets ONLY the node reach the bastion; run this on the bastion/admin host.
set -euo pipefail
unset REGISTRY_AUTH_FILE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$REPO_ROOT/scripts/lib/release.sh"
load_release_defaults
CONFIG="${IMAGESET_CONFIG:-$REPO_ROOT/install/imageset-config.yaml}"
# Capture relative overrides against the caller's cwd, independently of the checkout.
[[ "$CONFIG" == /* ]] || CONFIG="$PWD/$CONFIG"
WORKSPACE="${WORKSPACE:-file://${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}/mirror}"
case "$WORKSPACE" in file://*) RES_ROOT="${WORKSPACE#file://}" ;; *) echo "ERROR: WORKSPACE must be a file:// path" >&2; exit 2 ;; esac
[[ -n "$RES_ROOT" ]] || { echo "ERROR: empty mirror workspace" >&2; exit 2; }
[[ "$RES_ROOT" == /* ]] || RES_ROOT="$PWD/$RES_ROOT"
WORKSPACE="file://$RES_ROOT"   # oc-mirror v2 workspace (cache + generated resources)
MODE="${1:-mirror}"

# Endpoint seam (#26): ARTIFACTORY_REGISTRY is canonical; MIRROR_REGISTRY is the legacy alias.
MIRROR_REGISTRY="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-}}"


OCM="oc-mirror"
TOOL_DIR="${BIN_DIR:-${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}/bin}"
[[ ! -x "$TOOL_DIR/oc-mirror" ]] || OCM="$TOOL_DIR/oc-mirror"

case "${MODE}" in
  mirror)
    require_resolved_release
    : "${MIRROR_REGISTRY:?set ARTIFACTORY_REGISTRY (or MIRROR_REGISTRY)=<host:port>}"
    [[ -f "$CONFIG" ]] || { echo "ERROR: imageset config missing: $CONFIG" >&2; exit 2; }
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
    RES_DIR="$RES_ROOT/working-dir/cluster-resources"
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
    echo "usage: ARTIFACTORY_REGISTRY=<host:port> $0 {mirror|resources}  (legacy MIRROR_REGISTRY honored)" >&2
    exit 2
    ;;
esac
