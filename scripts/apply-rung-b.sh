#!/usr/bin/env bash
# Render initdata, launch rung-b, and wait until the encrypted-image pod runs.
set -euo pipefail

RUNG=b exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-rung-image.sh"
