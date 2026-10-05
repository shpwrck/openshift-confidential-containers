# AMD firmware preflight

Use this before acknowledging the BIOS gate for a fresh install on the disposable AMD rig. Record the actual machine and its evidence outside the checkout. A provider plan name, a CPU feature flag or a saved BIOS selection does not establish working SNP. This guide separates three requirements: the selected UEFI boot path, functional SNP host prerequisites, and the firmware's security-fix level. Guest launch and attestation are later proofs.

## Identify the machine and boot path

Match the provider server ID to the console and SSH target. Record the CPU, system and motherboard models, BIOS version/date, BMC version, running kernel and command line. Identify the node independently of its bastion. A marketed CPU family does not establish which processor was delivered.

The current validation workflow requires UEFI boot. Inspect the firmware boot selection and confirm the running OS mode with `test -d /sys/firmware/efi`. Match the installer boot choice to the UEFI path and check again after RHCOS installation. A missing EFI directory means this boot did not establish UEFI; it does not itself prove the CPU cannot support SNP. Changing a firmware boot selection does not convert an existing legacy installation into a UEFI installation.

## Find the controls for this board

For **H12SSW-iNR/NTR**, the [Supermicro manual](https://www.supermicro.com/manuals/motherboard/EPYC7000/MNL-2284.pdf), printed pages 71–72, documents:

| Menu | Setting | Intended value |
|---|---|---|
| Advanced → CPU Configuration | SVM Mode | Enabled |
| Advanced → CPU Configuration | SMEE | Enabled |
| Advanced → NB Configuration | IOMMU | Enabled |

The manual does not document the later SEV/SNP/RMP controls. AMD's [SEV enablement guide 58207](https://docs.amd.com/v/u/en-US/58207-using-sev-with-amd-epyc-processors), revision 2.0, sections 2.1.3 and 3.1.3, documents the following for **EPYC 7003/Milan**:

- In the reference firmware's **Advanced → AMD CBS → CPU Common Options**, enable SMEE; set **SEV-ES ASID Space Limit Control** to **Manual**; select a supported ASID count, **253 or 509**, and a space limit greater than **1**. A limit of `100` reserves 99 IDs for SEV-ES/SNP guests.
- Set **SNP Memory (RMP Table) Coverage** to **Enabled**, covering all system memory for the Linux host. This reservation is required even if a board does not expose the reference firmware's control; an absent menu item does not waive the host's RMP check.
- Under **AMD CBS → NBIO Common Options**, enable **IOMMU** and **SEV-SNP Support**.

Supermicro can expose these under its CPU Configuration and NB Configuration menus instead of AMD CBS. Inspect the visible settings and help text; do not navigate by an assumed number of keystrokes. TSME is separate from SMEE and is not an additional SNP prerequisite. Do not transplant the H13/Genoa `SEV Control` recipe into a Milan menu that uses the Manual ASID control.

### H12 observations from the October 5, 2026 preflight

The delivered **AS-1114S-WN10RT / H12SSW-NTR / EPYC 7313P**, BIOS **2.3**, initially showed:

| Menu | Initial observation |
|---|---|
| Advanced → CPU Configuration | SVM Enabled; SMEE Auto; SEV ASID Count Auto, offering 253/509 |
| Advanced → CPU Configuration | SEV-ES ASID Space Limit Control Auto; selecting Manual exposed a limit of 1 |
| Advanced → NB Configuration | IOMMU Auto; SEV-SNP Support explicitly Disabled |
| Inspected CPU menu | No RMP coverage control visible |

The later saved configuration was read back as SVM Enabled, SMEE Enabled, ASID count 509, Manual ASID limit 100, IOMMU Enabled and SNP Enabled. After reboot, `/dev/sev` existed, but the kernel reported that BIOS had not reserved RMP memory and that SEV initialization failed with `0x13`; the running `sev_snp` parameter remained `N`. The raw-host gate failed. The installed Rocky system was also booted in legacy mode.

A subsequent read-only serial-console inspection covered all **seven top-level tabs** and all **15 Advanced submenu roots**, including the CPU information, NB memory information/configuration/LCLK, serial-port/console, SATA/controller, TLS certificate, IPMI, event-log, Secure Boot and boot-priority submenus. Scrolling CPU, NB, PCI, Security and Boot pages were inspected. No RMP coverage control was exposed under the saved SNP-enabled configuration. Disabled controls were not unlocked by changing unrelated settings; password, erase, key enrollment/deletion, boot deletion, reset-defaults and firmware-update actions were not executed. The inspection ended with **Discard Changes and Exit**, with no configuration changes or flash.

The inspection confirmed BMC **01.00.41**, CPU microcode **A001143**, PSP bootloader **0.13.0.67** and ABL **10065011**. The protected `node-bios-menu-inspection.json` records the screens and the October 5, 2026 inspection window, **15:17:15–15:27:43 UTC**. This is evidence about the exposed BIOS interface; it does not establish that every vendor configuration interface lacks an RMP setting.

This result blocks the install on this configuration. It does not prove that EPYC 7313P or the provider cannot support SNP, or that changing a single control will fix every initialization error. Retain the full post-boot log, then have the provider identify the supported RMP enablement path or supply suitable updated firmware or replacement hardware. Recheck the result after any change; a BIOS selection or `/dev/sev` alone is insufficient.

The [historical host proof](notes/latitude-snp-bringup.md) records **EPYC 9124/Genoa in NYC**; the [July 28 BIOS inspection](notes/latitude-bios/README.md) records **H13SST-G, BIOS 3.0 built October 4, 2024**, with an exposed RMP coverage setting. The current **Dallas** allocation is **EPYC 7313P/Milan, H12SSW-NTR, BIOS 2.3 dated October 28, 2021**. It is an older, different platform, rather than a repeat of the previously working hardware. The shared `m4-metal-medium` plan label does not guarantee identical delivered hardware across regions or allocations; confirm the actual CPU, board and firmware.

The current failure occurs at the raw-host firmware/SNP gate before OpenShift installation. It does not establish an OSC regression or that Milan cannot support SNP. Prioritize an allocation matching the advertised EPYC 9124 with verified SNP firmware, or a provider-supported resolution on the delivered board. Historical Auto-setting explanations and memory-interleaving workarounds are not universal diagnoses for H12 or every IOMMU/PSP error.

## Review firmware security separately

There is no global BIOS version comparison across boards. Check the exact model's vendor security advisories and the actual running firmware, microcode and attested TCB. Functional SNP initialization on old firmware does not establish that known vulnerabilities are fixed.

For H12SSW-iNR/NTR, published fixes include:

| Vendor advisory | BIOS version listed with the fix |
|---|---|
| [AMD-SB-3019, SEV protection vulnerability](https://www.supermicro.com/en/support/security_AMD-SB-3019) | 3.1 |
| [AMD-SB-3020, RMP initialization vulnerability](https://www.supermicro.com/en/support/security_AMD-SB-3020?mlg=0) | 3.5 |
| [AMD-SB-3030, May 2026 SNP-related fixes](https://www.supermicro.com/en/support/security_AMD-SB-3030) | 3.6 |

The [AS-1114S-WN10RT catalog](https://www.supermicro.com/en/support/resources/downloadcenter/firmware/AS-1114S-WN10RT/BIOS) listed BIOS **3.6** and BMC **01.08.06** when checked on October 5, 2026. BIOS 2.3 is below these published fix versions. These are security-fix thresholds, not the first firmware version that enabled SNP, and the table is not a complete vulnerability inventory. Resolve the firmware gap with the provider before using this machine as a current secure customer baseline. Any separately accepted functional experiment must retain that limitation in its evidence; a functional pass cannot clear it.

### Update or replace the delivered node

The exact system's [BIOS 3.6 release notes](https://www.supermicro.com/Bios/softfiles/30657/H12SSW-NTR_BIOS_3_6_release_notes.pdf), dated December 17, 2025, update Milan AGESA to **1.0.0.J**; the 2.3 history lists **1.0.0.6**. The [BMC 01.08.06 release notes](https://www.supermicro.com/Bios/softfiles/30657/H12SSW_NTR_IPMI_01_08_06_release_notes.pdf), dated April 27, 2026, identify H12SSW-NTR as a Root of Trust platform. Both list dependencies as N/A and direct use of their packaged flash utility. The current bundle is `H12SSW-NTR_3.6_AS01.08.06_SAA1.5.0-p5.zip`. Its archive instructions have not been inspected, and the release notes alone do not establish the safe update sequence from BIOS 2.3/BMC 01.00.41. They also do not promise that BIOS 3.6 exposes RMP coverage or fixes this initialization failure.

Latitude documents [IPMI/KVM access](https://www.latitude.sh/docs/servers/remote-access) and [BIOS access through its serial console](https://www.latitude.sh/docs/servers/out-of-band). No explicit permission or prohibition for customer firmware flashing was found in the public documentation checked on October 5, 2026. Have Latitude perform the update or confirm the exact package, procedure and recovery arrangement; a replacement with suitable firmware is another option. The support request remains an unsent draft.

Firmware flashing, resetting defaults and changing unrelated security controls are not part of this preflight. The H12 manual documents **Save & Exit → Save Changes and Reset** for ordinary configuration changes; read back the settings after they take effect.

A provider-assisted BIOS configuration export may help determine whether a setting exists outside the visible menu. The [SUM 2.15.0 guide](https://www.supermicro.com/Bios/sw_download/1026/SUM_UserGuide.pdf), pages 236–237 and 708, documents in-band `GetCurrentBiosCfg` without BMC network credentials, but requires a node product key (**SFT-OOB-LIC** or **SFT-DCMS-SINGLE**) even for this export. Root access, a supported platform/OS and working local IPMI access remain prerequisites; applicability on this node's Rocky image has not been validated. A plain export is read-only; do not use its editable TUI or a configuration-write command as part of inspection. No utility was installed or run, and no exported RMP property is established. Do not invent a setting name or import configuration from another BIOS version.

For an updated or replacement node, repeat the identity and security review against the delivered board, verify the saved SNP settings and full-memory RMP reservation, and confirm the intended UEFI boot path. Capture a new raw-host check and current-boot kernel log before installation. A provider's statement that SNP is available is useful for selecting the machine; the running host and later guest proofs establish the validation result.

## Establish and retain the functional result

Run `sudo bash scripts/host-snp-check.sh` on the raw node, from a copy of the reviewed script. It reads the current module, device and kernel logs; it does not load modules or alter firmware. Record its exit status and output alongside the board, boot mode and firmware evidence.

- An unloaded `kvm_amd` module is incomplete evidence. Decide deliberately whether to load it, then rerun the check; do not label its absence a BIOS failure.
- A missing SNP module parameter requires kernel/module capability diagnosis. Kernel version alone is insufficient because distributions backport support.
- A disabled SNP parameter requires inspection of module options, kernel command line, exact initialization errors and firmware settings. A CCP/PSP/SEV error `0x3` does not uniquely identify memory interleaving as the cause.
- Require the enabled running SNP parameter, `/dev/sev`, readable initialization logs, SEV-SNP API and RMP evidence. After installation, repeat verification under the actual RHCOS kernel before launching the guest proofs.

The Ansible gate retains **SNP-SET** as its explicit acknowledgement token. Enter it only after the identity, firmware review, UEFI and raw-host functional checks above are complete. The token does not execute these checks. `skip_bios_pause=true` retains its existing meaning for a deliberate unattended rerun after that evidence exists; it does not waive the preflight. Recheck after reprovisioning or firmware changes rather than assuming saved settings persisted.
