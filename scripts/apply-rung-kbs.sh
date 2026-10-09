#!/usr/bin/env bash
set -euo pipefail
export RUNG=kbs
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/apply-workload.sh"
