#!/usr/bin/env bash
# Rung-0 gate: prove AMD SEV-SNP *host* is live on an OpenShift node BEFORE any GitOps.
# This is the verify-first step — if it fails, the bare-metal decision is invalid for this
# provider/node and we stop (fall back to peer-pods / a different node).
#
# Usage: ./scripts/verify-snp-host.sh <node-name>
set -euo pipefail

NODE="${1:?usage: verify-snp-host.sh <node-name>}"
fail=0
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

dbg() { oc debug "node/${NODE}" --quiet -- chroot /host bash -c "$1" 2>/dev/null; }

echo "== SEV-SNP host gate on ${NODE} =="

# 1. PSP / firmware healthy, RMP table present, no INVALID_CONFIG (0x3 = Memory Interleaving off)
SEV_DMESG="$(dbg "dmesg | grep -E 'ccp.*SEV|SEV-SNP|kvm_amd.*SEV' || true")"
echo "${SEV_DMESG}" | sed 's/^/    /'
chk "PSP reports SEV-SNP API"      "echo \"\$SEV_DMESG\" | grep -qi 'SEV-SNP API'"
chk "RMP table initialized"        "echo \"\$SEV_DMESG\" | grep -qi 'RMP table'"
chk "no PSP Error: 0x3 (BIOS Memory Interleaving)"  "! echo \"\$SEV_DMESG\" | grep -qi 'Error: 0x3'"

# 2. KVM host SNP enabled
SNP_PARAM="$(dbg "cat /sys/module/kvm_amd/parameters/sev_snp 2>/dev/null || echo N")"
chk "kvm_amd sev_snp = Y"          "[ \"${SNP_PARAM}\" = Y ]"

# 3. CPU generation (informational — drives KDS product string + bug #591)
echo "    CPU: $(dbg "lscpu | grep 'Model name' | sed 's/.*: *//'")"

# 4. SNP device node present
chk "/dev/sev present"             "dbg 'test -e /dev/sev && echo y' | grep -q y"

echo
if [ "${fail}" -eq 0 ]; then
	echo "RESULT: SEV-SNP host is LIVE — proceed to GitOps."
else
	echo "RESULT: GATE FAILED — do NOT proceed. Fix BIOS (SEV-SNP/Memory Interleaving/SMEE) or"
	echo "        re-evaluate provider/node. See docs/design/engagement-design.md."
	exit 1
fi
