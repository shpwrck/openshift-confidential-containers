#!/usr/bin/env bash
# Render initdata, launch rung-c, and wait until the encrypted-image pod runs.
set -euo pipefail

RUNG=c exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply-rung-image.sh"
