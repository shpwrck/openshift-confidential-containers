#!/usr/bin/env bash
# Render initdata, launch the signed-image workload, and wait until the pod runs (rung-signed).
set -euo pipefail

RUNG=signed exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-rung-image.sh"
