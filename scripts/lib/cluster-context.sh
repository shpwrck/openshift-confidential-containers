#!/usr/bin/env bash
# Explicit cluster selection for operations; rendering does not call this loader.

load_worker_context() {
  if [[ -z "${WORKER_CONTEXT:-}" ]]; then
    echo "ERROR: set WORKER_CONTEXT to the intended oc context (oc config get-contexts)." >&2
    return 2
  fi
  export WORKER_CONTEXT
}

load_cluster_contexts() {
  load_worker_context || return
  if [[ -z "${TRUSTEE_CONTEXT:-}" ]]; then
    if [[ "${TRUSTEE_LAB:-0}" == "1" ]]; then
      TRUSTEE_CONTEXT="$WORKER_CONTEXT"
    else
      echo "ERROR: set TRUSTEE_CONTEXT; use TRUSTEE_LAB=1 only for a disposable co-located rig." >&2
      return 2
    fi
  fi
  export WORKER_CONTEXT TRUSTEE_CONTEXT
}

worker_oc() { command oc --context="$WORKER_CONTEXT" --request-timeout="${OC_REQUEST_TIMEOUT:-30s}" "$@"; }
trustee_oc() { command oc --context="$TRUSTEE_CONTEXT" --request-timeout="${OC_REQUEST_TIMEOUT:-30s}" "$@"; }
