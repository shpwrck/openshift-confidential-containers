#!/usr/bin/env bash
# Encode/decode CoCo initdata for the pod annotation io.katacontainers.config.hypervisor.cc_init_data.
#
# The annotation value is the initdata TOML, gzip-compressed then base64-encoded (the same TOML
# is hardware-measured into HOST_DATA). This helper does ONLY that mechanical transform; fill the
# KBS Route URL + Trustee CA in the TOML first (see gitops/base/workloads/initdata.example.toml).
#
#   encode-initdata.sh encode <initdata.toml>   -> prints the gzip+base64 annotation value
#   encode-initdata.sh decode <annotation-value> -> prints the original TOML (for debugging:
#                                                    "decode initdata" in docs/runbooks/failure-modes.md)
#
# VERIFY the compression/encoding against the OSC 1.12 guest-components expectation before first
# use (some builds expect raw base64 TOML, others gzip+base64). This script assumes gzip+base64.
set -euo pipefail

MODE="${1:-}"; ARG="${2:-}"
case "$MODE" in
  encode)
    [ -f "$ARG" ] || { echo "usage: $0 encode <initdata.toml>" >&2; exit 2; }
    if grep -q '__KBS_URL__\|__TRUSTEE_CA_PEM__' "$ARG"; then
      echo "REFUSING: $ARG still has __KBS_URL__/__TRUSTEE_CA_PEM__ placeholders — fill them first." >&2
      exit 3
    fi
    gzip -n -c "$ARG" | base64 | tr -d '\n'; echo   # `base64 | tr` is portable; `-w0` is GNU-only
    ;;
  decode)
    [ -n "$ARG" ] || { echo "usage: $0 decode <annotation-value|-> (use - to read stdin)" >&2; exit 2; }
    # portable decode flag: GNU base64 uses -d, BSD/macOS uses -D
    if printf '' | base64 -d >/dev/null 2>&1; then _d=-d; else _d=-D; fi
    { [ "$ARG" = "-" ] && cat || printf '%s' "$ARG"; } | base64 "$_d" | gunzip -c
    ;;
  *)
    echo "usage: $0 {encode <file.toml>|decode <value|->}" >&2; exit 2 ;;
esac
