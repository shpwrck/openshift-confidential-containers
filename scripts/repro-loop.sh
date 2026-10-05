#!/usr/bin/env bash
# Reuse prepared artifacts, but always rerun the security proofs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/run-proofs.py" all "$@"
