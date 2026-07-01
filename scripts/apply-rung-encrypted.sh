#!/usr/bin/env bash
# Render initdata, launch the encrypted-image workload, and wait until the pod runs (rung-encrypted).
set -euo pipefail

RUNG=encrypted exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-rung-image.sh"
