#!/usr/bin/env bash
# Read-only raw-host SEV-SNP prerequisite check, before installing OpenShift.
# The OpenShift-node equivalent is scripts/verify-snp-host.sh. Kernel versions
# are informational: distribution kernels can backport SNP host support.
# This script never loads modules, changes firmware, or proves guest attestation.
set -uo pipefail
fail=0
report() {
  local label="$1"
  shift
  if "$@"; then echo "  PASS  $label"; else echo "  FAIL  $label"; fail=1; fi
}

echo "== SEV-SNP host gate (raw host $(hostname)) =="
echo "  kernel: $(uname -r)   cpu: $(lscpu | sed -n 's/^Model name: *//p')"

# Prefer the running module over metadata for an on-disk module, which could
# differ after package updates. Do not infer BIOS state from an unloaded module.
MODULE_LOADED=0
KERNEL_CAPABLE=unknown
if [ -d /sys/module/kvm_amd ]; then
  MODULE_LOADED=1
  KERNEL_CAPABLE=no
  if [ -e /sys/module/kvm_amd/parameters/sev_snp ]; then KERNEL_CAPABLE=yes; fi
elif MODULE_PARAMETERS="$(modinfo -p kvm_amd 2>/dev/null)"; then
  KERNEL_CAPABLE=no
  if grep -Eq '^sev_snp:' <<< "$MODULE_PARAMETERS"; then KERNEL_CAPABLE=yes; fi
fi
report "kvm_amd exposes the SNP host parameter" test "$KERNEL_CAPABLE" = yes
report "kvm_amd is loaded" test "$MODULE_LOADED" -eq 1

PARAM_READABLE=0
SNP_PARAM=
if SNP_PARAM="$(cat /sys/module/kvm_amd/parameters/sev_snp 2>/dev/null)"; then
  PARAM_READABLE=1
fi
report "kvm_amd sev_snp = Y" test "$SNP_PARAM" = Y
report "/dev/sev present" test -e /dev/sev

# Read logs once. An inaccessible log is missing evidence, not proof that PSP
# or firmware initialization failed. Scope error codes to the relevant driver.
DMESG_READABLE=0
if HOST_DMESG="$(dmesg 2>/dev/null)"; then DMESG_READABLE=1; fi
SEV_DMESG="$(grep -Ei 'ccp.*SEV|SEV-SNP|RMP table|kvm_amd.*SEV|AMD-Vi.*SNP' <<< "$HOST_DMESG" || true)"
if [ -n "$SEV_DMESG" ]; then printf '%s\n' "$SEV_DMESG" | sed 's/^/    /'; fi
PSP_INVALID_CONFIG=0
if grep -Ei '(^|[^[:alnum:]_])(ccp|psp|sev)([^[:alnum:]_]|$)' <<< "$HOST_DMESG" |
    grep -Ei 'error:[[:space:]]*0x0*3([^[:xdigit:]]|$)' >/dev/null; then
  PSP_INVALID_CONFIG=1
fi
# Require the kernel's positive physical allocation record, not any mention of
# RMP: a missing reservation error also contains the words "RMP table".
RMP_RANGE_PATTERN='SEV-SNP:[[:space:]]+RMP table physical (address|range)[[:space:]]+\[?0x[[:xdigit:]]+[[:space:]]*-[[:space:]]*0x[[:xdigit:]]+\]?[[:space:]]*$'
RMP_FAILURE=0
if grep -Ei 'SEV-SNP:.*(Memory for the RMP table has not been reserved|RMP configuration not valid|Memory reserved for the RMP table does not cover|Failed to map RMP table)' <<< "$HOST_DMESG" >/dev/null; then
  RMP_FAILURE=1
fi
PSP_INIT_FAILED=0
if grep -Ei '(^|[^[:alnum:]_])(ccp|psp|sev)([^[:alnum:]_]|$)' <<< "$HOST_DMESG" |
    grep -Ei '(INIT(_EX)?[[:space:]]+failed|failed[[:space:]]+to[[:space:]]+INIT(_EX)?)' >/dev/null; then
  PSP_INIT_FAILED=1
fi
report "kernel log readable" test "$DMESG_READABLE" -eq 1
report "PSP reports SEV-SNP API" grep -qi 'SEV-SNP API' <<< "$SEV_DMESG"
report "RMP physical allocation range reported" grep -Eqi "$RMP_RANGE_PATTERN" <<< "$SEV_DMESG"
report "no RMP reservation/mapping failure" test "$RMP_FAILURE" -eq 0
report "no CCP/PSP/SEV INVALID_CONFIG error (0x3)" test "$PSP_INVALID_CONFIG" -eq 0
report "no CCP/PSP/SEV initialization failure" test "$PSP_INIT_FAILED" -eq 0

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: SEV-SNP host prerequisites passed. Guest launch and attestation remain separate proofs."
  echo "        Repeat host verification under RHCOS with scripts/verify-snp-host.sh."
  exit 0
fi
echo "RESULT: host gate not passed; this does not establish a provider veto."
if [ "$KERNEL_CAPABLE" = unknown ]; then
  echo "  -> CAPABILITY UNKNOWN: kvm_amd is not loaded and module metadata is unavailable."
  echo "     Check the installed kernel/module package and modinfo availability."
elif [ "$KERNEL_CAPABLE" = no ]; then
  echo "  -> KERNEL/IMAGE: kvm_amd does not expose the SNP host parameter."
  echo "     Check this kernel's SNP host support; its version number alone is insufficient."
elif [ "$MODULE_LOADED" -eq 0 ]; then
  echo "  -> MODULE NOT LOADED: module metadata advertises SNP host support, but kvm_amd is absent."
  echo "     Load it deliberately when appropriate, then rerun; BIOS state is not established."
elif [ "$DMESG_READABLE" -eq 0 ] || [ "$PARAM_READABLE" -eq 0 ]; then
  echo "  -> INSUFFICIENT EVIDENCE: read the kernel log and running module parameter with sufficient privileges."
elif [ "$PSP_INVALID_CONFIG" -eq 1 ]; then
  echo "  -> PSP INVALID_CONFIG (0x3): inspect the exact CCP/PSP/SEV error and platform firmware configuration."
  echo "     Memory interleaving was a cause on a historical rig; this error alone does not identify the cause."
elif [ "$PSP_INIT_FAILED" -eq 1 ]; then
  echo "  -> PSP INITIALIZATION FAILED: retain the exact firmware status and kernel error."
  echo "     A device node or positive API/range message does not override this failure."
elif [ "$RMP_FAILURE" -eq 1 ]; then
  echo "  -> RMP RESERVATION/MAPPING FAILED: inspect this board's firmware allocation and the exact kernel error."
elif [ "$SNP_PARAM" != Y ]; then
  echo "  -> SNP NOT ENABLED in the running kvm_amd module. Inspect kernel command-line/module options,"
  echo "     initialization logs, and this board's BIOS settings before making firmware changes."
else
  echo "  -> INCOMPLETE HOST EVIDENCE: inspect the failed device/log checks and exact initialization errors."
  echo "     Do not infer a firmware or provider limitation from these missing checks alone."
fi
exit 1
