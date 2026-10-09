#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release.sh"

load_tee_profile() {
  TEE="${TEE:-snp}"
  case "$TEE" in snp) ;; *) echo "ERROR: this deployment supports TEE=snp only" >&2; return 2 ;; esac
  COCO_RUNTIMECLASS="$(release_value "profiles.${TEE}.runtimeClass")" || return
  COCO_RUNTIME_HANDLER="$(release_value "profiles.${TEE}.runtimeHandler")" || return
  COCO_NODE_LABEL="$(release_value "profiles.${TEE}.nodeLabel")" || return
  COCO_WORKER_POOL_LABEL="$(release_value "profiles.${TEE}.workerPoolLabel")" || return
  COCO_WORKER_POOL_VALUE="$(release_value "profiles.${TEE}.workerPoolValue")" || return
  COCO_NFD_PATH="$(release_value "profiles.${TEE}.nfdPath")" || return
  export TEE COCO_RUNTIMECLASS COCO_RUNTIME_HANDLER COCO_NODE_LABEL COCO_WORKER_POOL_LABEL COCO_WORKER_POOL_VALUE COCO_NFD_PATH
}
