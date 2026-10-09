#!/usr/bin/env bash
# Shared non-secret release defaults. Sourcing never contacts a cluster or registry.
_COCO_RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

release_value() {
  python3 "${_COCO_RELEASE_ROOT}/scripts/verify-release.py" \
    --manifest "${RELEASE_MANIFEST:-${_COCO_RELEASE_ROOT}/install/release-manifest.json}" --get "$1"
}

load_release_defaults() {
  OCP_VERSION="${OCP_VERSION:-$(release_value platform.version)}" || return
  OCP_RELEASE_IMAGE="${OCP_RELEASE_IMAGE:-$(release_value platform.releaseImage)}" || return
  OCP_CLIENTS_BASE="${OCP_CLIENTS_BASE:-$(release_value platform.clientBase)}" || return
  OSC_VERSION="${OSC_VERSION:-$(release_value operators.osc.version)}" || return
  TRUSTEE_VERSION="${TRUSTEE_VERSION:-$(release_value operators.trustee.version)}" || return
  CATALOGSOURCE="${CATALOGSOURCE:-$(release_value catalog.source)}" || return
  TOOLS_IMG="${TOOLS_IMG:-$(release_value images.cocoTools.ref)}" || return
  IMAGESET_CONFIG="${IMAGESET_CONFIG:-${_COCO_RELEASE_ROOT}/$(release_value "profiles.${TEE:-snp}.imageSet")}" || return
  export OCP_VERSION OCP_RELEASE_IMAGE OCP_CLIENTS_BASE OSC_VERSION TRUSTEE_VERSION CATALOGSOURCE TOOLS_IMG IMAGESET_CONFIG
}

require_resolved_release() {
  python3 "${_COCO_RELEASE_ROOT}/scripts/verify-release.py" \
    --manifest "${RELEASE_MANIFEST:-${_COCO_RELEASE_ROOT}/install/release-manifest.json}" \
    --tee "${TEE:-snp}" --require-resolved
}
