#!/usr/bin/env bash
# Raw-host SEV-SNP HOST check — run directly on the bare Latitude Ubuntu node (pre-OpenShift).
# Provider/hardware gate for rung-0. The OpenShift-node equivalent is scripts/verify-snp-host.sh.
#
# IMPORTANT (anti-false-negative): a plain "sev_snp=N" is ambiguous. This script DISCRIMINATES:
#   - kernel lacks SNP-host capability      -> kernel/image problem (NOT a provider veto)
#   - kernel-capable but sev_snp=N          -> BIOS toggle off/unreachable (flip in AMD CBS via IPMI)
#   - kernel-capable + BIOS on + still fails -> genuine provider/firmware veto
# Only the last justifies abandoning the bare-metal path. A green result here proves the
# SILICON+PROVIDER do SNP host; it does NOT prove the RHCOS kernel (verified at the OpenShift phase).
set -uo pipefail
fail=0
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

echo "== SEV-SNP host gate (raw host $(hostname)) =="
echo "  kernel: $(uname -r)   cpu: $(lscpu | sed -n 's/^Model name: *//p')"

# --- Kernel capability (independent of BIOS) -------------------------------
KREL="$(uname -r | cut -d. -f1-2)"
chk "kernel >= 6.11"               "awk -v k=\"$KREL\" 'BEGIN{split(k,a,\".\"); exit !((a[1]>6)||(a[1]==6&&a[2]>=11))}'"
KCONF="/boot/config-$(uname -r)"
KERNEL_CAPABLE=1
chk "CONFIG_KVM_AMD_SEV=y in kernel"  "test -f \"$KCONF\" && grep -q '^CONFIG_KVM_AMD_SEV=y' \"$KCONF\""
grep -q '^CONFIG_KVM_AMD_SEV=y' "$KCONF" 2>/dev/null || KERNEL_CAPABLE=0
# kvm_amd must expose the sev_snp parameter at all (proves host SNP compiled in)
chk "kvm_amd exposes sev_snp param"  "modinfo kvm_amd 2>/dev/null | grep -qi 'parm:.*sev_snp' || test -e /sys/module/kvm_amd/parameters/sev_snp"
modinfo kvm_amd 2>/dev/null | grep -qi 'parm:.*sev_snp' || test -e /sys/module/kvm_amd/parameters/sev_snp || KERNEL_CAPABLE=0

# --- PSP / firmware + BIOS-dependent bring-up ------------------------------
SEV_DMESG="$(dmesg 2>/dev/null | grep -Ei 'ccp.*SEV|SEV-SNP|RMP table|kvm_amd.*SEV' || true)"
echo "${SEV_DMESG}" | sed 's/^/    /'
chk "PSP reports SEV-SNP API"      "echo \"\$SEV_DMESG\" | grep -qi 'SEV-SNP API'"
chk "RMP table initialized"        "echo \"\$SEV_DMESG\" | grep -qi 'RMP table'"
chk "no PSP Error: 0x3 (Mem Interleaving)" "! dmesg 2>/dev/null | grep -qi 'Error: 0x3'"
SNP_PARAM="$(cat /sys/module/kvm_amd/parameters/sev_snp 2>/dev/null || echo N)"
chk "kvm_amd sev_snp = Y"          "[ \"${SNP_PARAM}\" = Y ]"
chk "/dev/sev present"             "test -e /dev/sev"

# --- Verdict with discrimination -------------------------------------------
echo
if [ "${fail}" -eq 0 ]; then
  echo "RESULT: SEV-SNP host LIVE (silicon+provider proven). Next: launch one SNP guest"
  echo "        (snpguest), then install SNO and run scripts/verify-snp-host.sh."
  exit 0
fi
echo "RESULT: not yet live — diagnose, do NOT conclude 'provider can't do SNP' yet:"
if [ "${KERNEL_CAPABLE}" -eq 0 ]; then
  echo "  -> KERNEL/IMAGE problem: this kernel lacks SNP-host support. Boot a newer/SNP-enabled"
  echo "     kernel (Ubuntu 25.04+/26.04, or build AMDSEV). This is NOT a provider veto."
elif dmesg 2>/dev/null | grep -qi 'Error: 0x3'; then
  echo "  -> BIOS: Memory Interleaving is enabled (PSP Error 0x3). Disable it in AMD CBS via IPMI."
elif [ "${SNP_PARAM}" != Y ]; then
  echo "  -> BIOS: kernel CAN do SNP host but sev_snp=N => SEV-SNP toggle is off/unreachable."
  echo "     Open the Latitude IPMI console -> reboot -> AMD CBS: enable SEV-SNP Support + SMEE,"
  echo "     set SEV-ES ASID Space Limit > 0, enable RMP Table. Re-run. NOT yet a provider veto."
else
  echo "  -> Kernel-capable AND BIOS appears on, yet SNP won't init => likely PSP firmware too old"
  echo "     or genuine provider/firmware veto. THIS is the case that justifies a provider fallback."
fi
exit 1
