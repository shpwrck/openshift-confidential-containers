#!/usr/bin/env bash
# Paired positive, attributable negative, restore and recovery proofs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/run-proofs.py" "$@"
