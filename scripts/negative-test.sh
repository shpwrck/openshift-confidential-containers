#!/usr/bin/env bash
# A negative is meaningful only with its positive and recovery controls.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/run-proofs.py" "$@"
