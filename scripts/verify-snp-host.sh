#!/usr/bin/env bash
# Rung-0 gate: prove AMD SEV-SNP *host* prerequisites are present on an OpenShift node BEFORE any GitOps.
# A failure blocks progress and requires diagnosis; it does not establish a provider veto.
#
# Usage: ./scripts/verify-snp-host.sh <node-name>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/cluster-context.sh"
load_worker_context

NODE="${1:?usage: verify-snp-host.sh <node-name>}"
fail=0
chk() {
  local label="$1"
  shift
  if "$@"; then echo "  PASS  $label"; else echo "  FAIL  $label"; fail=1; fi
}

dbg() { worker_oc debug "node/${NODE}" --quiet -- chroot /host bash -c "$1" 2>/dev/null; }

echo "== SEV-SNP host gate on ${NODE} =="

# 1. Require positive allocation evidence and reject initialization errors,
# even when another line advertises an API version or physical RMP range.
DMESG_READABLE=0
if HOST_DMESG="$(dbg dmesg)"; then DMESG_READABLE=1; fi
SEV_DMESG="$(grep -Ei 'ccp.*SEV|SEV-SNP|RMP table|kvm_amd.*SEV|AMD-Vi.*SNP' <<< "$HOST_DMESG" || true)"
echo "${SEV_DMESG}" | sed 's/^/    /'
RMP_RANGE_PATTERN='SEV-SNP:[[:space:]]+RMP table physical (address|range)[[:space:]]+\[?0x[[:xdigit:]]+[[:space:]]*-[[:space:]]*0x[[:xdigit:]]+\]?[[:space:]]*$'
RMP_FAILURE=0
if grep -Ei 'SEV-SNP:.*(Memory for the RMP table has not been reserved|RMP configuration not valid|Memory reserved for the RMP table does not cover|Failed to map RMP table)' <<< "$HOST_DMESG" >/dev/null; then
  RMP_FAILURE=1
fi
PSP_INVALID_CONFIG=0
if grep -Ei '(^|[^[:alnum:]_])(ccp|psp|sev)([^[:alnum:]_]|$)' <<< "$HOST_DMESG" |
    grep -Ei 'error:[[:space:]]*0x0*3([^[:xdigit:]]|$)' >/dev/null; then
  PSP_INVALID_CONFIG=1
fi
PSP_INIT_FAILED=0
if grep -Ei '(^|[^[:alnum:]_])(ccp|psp|sev)([^[:alnum:]_]|$)' <<< "$HOST_DMESG" |
    grep -Ei '(INIT(_EX)?[[:space:]]+failed|failed[[:space:]]+to[[:space:]]+INIT(_EX)?)' >/dev/null; then
  PSP_INIT_FAILED=1
fi
chk "kernel log readable" test "$DMESG_READABLE" -eq 1
chk "PSP reports SEV-SNP API" grep -qi 'SEV-SNP API' <<< "$SEV_DMESG"
chk "RMP physical allocation range reported" grep -Eqi "$RMP_RANGE_PATTERN" <<< "$SEV_DMESG"
chk "no RMP reservation/mapping failure" test "$RMP_FAILURE" -eq 0
chk "no CCP/PSP/SEV INVALID_CONFIG error (0x3)" test "$PSP_INVALID_CONFIG" -eq 0
chk "no CCP/PSP/SEV initialization failure" test "$PSP_INIT_FAILED" -eq 0

# 2. KVM host SNP enabled
SNP_PARAM="$(dbg "cat /sys/module/kvm_amd/parameters/sev_snp 2>/dev/null || echo N")"
chk "kvm_amd sev_snp = Y" test "$SNP_PARAM" = Y

# 3. CPU generation (informational — drives KDS product string + bug #591)
echo "    CPU: $(dbg "lscpu | grep 'Model name' | sed 's/.*: *//'")"

# 4. SNP device node present
chk "/dev/sev present" dbg 'test -e /dev/sev'

echo
if [ "${fail}" -eq 0 ]; then
	echo "RESULT: SEV-SNP host checks passed; quote verification and attestation are separate proofs."
else
	echo "RESULT: GATE FAILED — do NOT proceed. Inspect the failed checks and exact initialization errors."
	echo "        See docs/amd-firmware-preflight.md; this does not establish a provider veto."
	exit 1
fi
