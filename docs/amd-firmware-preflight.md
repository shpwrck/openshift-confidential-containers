# AMD firmware preflight

Run this before acknowledging the BIOS gate. A plan name, CPU flag, saved BIOS
selection or `/dev/sev` alone does not prove working SEV-SNP.

## Identify the delivered machine

Match the provider server ID to SSH and the console. Record CPU, system/board,
BIOS/BMC versions, kernel, command line and disk serial in protected external evidence.
The installation path requires UEFI; verify both the firmware selection and
`test -d /sys/firmware/efi` on the running OS. Changing a BIOS boot selection does
not convert an existing legacy installation to UEFI.

## Set the board's SNP controls

The October 8 **H13SST-G / EPYC 9124 / BIOS 3.7** trial used:

| Setting | Value |
|---|---|
| SVM / SEV | Enabled (already set on the trial) |
| SMEE | Enabled |
| SNP Memory / RMP Table Coverage | Enabled, covering all system memory |
| SEV-ES ASID Space Limit | 100 on this tested board |
| IOMMU | Enabled |
| SEV-SNP Support | Enabled |

These appeared under Advanced CPU/NB Configuration. Inspect the exact board's
menus and help text; H12/Milan can use different ASID controls. Do not transplant
an H13 key sequence or treat `Auto` as evidence of enablement. TSME is separate
from SMEE. No memory-interleaving change was needed for the successful trial.

BIOS console setup was manual. The tested Redfish BIOS endpoint required a licence.
Settings survived the Kata reboot, but must be verified after each reinstall or
firmware change. Use the [board manual](https://www.supermicro.com/en/support/resources)
and [AMD SEV enablement guide](https://docs.amd.com/v/u/en-US/58207-using-sev-with-amd-epyc-processors)
for the actual model.

## Review firmware security

Check the delivered model's vendor advisories and running firmware/microcode/TCB.
A functional SNP pass does not establish that known vulnerabilities are fixed;
BIOS version numbers cannot be compared across different boards.

A prior H12SSW-NTR/EPYC 7313P allocation failed to reserve RMP despite saved SNP
settings. A later H13 with old firmware initialized SNP but remained below published
security fixes. [Dated host evidence](validation/latitude-mia2-host-2026-10-05.json)
retains that distinction. Have the provider update or replace unsuitable hardware
using its supported recovery procedure; this repository does not flash firmware.

## Prove the running host

Copy the reviewed script to the raw node and run:

```bash
sudo bash /path/to/host-snp-check.sh
```

[The checker](../scripts/host-snp-check.sh) reads module/device/current-boot evidence;
it does not load modules or change firmware. Require `sev_snp=Y`, `/dev/sev`,
readable initialization logs, SNP API and initialized full-memory RMP evidence.
Retain its exit status and complete output with machine identity.

An unloaded `kvm_amd` module or missing SNP parameter needs kernel/module diagnosis.
A disabled parameter needs module-option, command-line and initialization-log checks.
A PSP error code alone does not uniquely identify a BIOS fix.

Enter the Ansible **SNP-SET** acknowledgement only after these checks pass.
`skip_bios_pause=true` acknowledges a previously verified unattended rerun; it does
not waive preflight. Repeat under installed RHCOS and after the Kata rollout,
then complete hardware-backed guest proofs.
