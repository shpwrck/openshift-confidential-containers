#!/usr/bin/env bash
set -euo pipefail
case "${RUNG:-}" in signed|encrypted) ;; *) echo 'Set RUNG=signed or encrypted' >&2; exit 2 ;; esac
export RUNG
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/apply-workload.sh"
