# AMD firmware preflight

Use this page for a board or provider that has not been tested. On a rig ordered
with `make order-rig`, `make check-node-snp` and the install already run the
identity, boot-mode and SEV-SNP checks before anything is erased; only the
firmware security review below stays yours.

A plan name, a CPU flag, a saved BIOS setting or `/dev/sev` alone does not prove
working SEV-SNP.

## Identify the delivered machine

Match the provider server ID to SSH and the console. Record CPU, system/board,
BIOS/BMC versions, kernel, command line and disk serial in protected external evidence.
The installation path requires UEFI; verify both the firmware selection and
`test -d /sys/firmware/efi` on the running OS. Changing a BIOS boot selection does
not convert an existing legacy installation to UEFI.

`make check-node-snp` and the install print most of this. On another server, on
the node's original OS:

```bash
lscpu | grep 'Model name'
sudo dmidecode -s system-product-name; sudo dmidecode -s baseboard-product-name
sudo dmidecode -s bios-version; sudo dmidecode -s bios-release-date
uname -r; cat /proc/cmdline
lsblk -d -o NAME,SERIAL,SIZE,MODEL
test -d /sys/firmware/efi && echo UEFI || echo 'NOT UEFI'
```

Read the BMC firmware version from the BMC web console, or with
`sudo ipmitool mc info` if `ipmitool` is installed.

## Set the board's SNP controls

The settings that worked on the tested Supermicro H13SST-G boards (EPYC 9124 and
9254, BIOS 3.7), and how to reach the BIOS through the Cherry console, are in
[Set the BIOS](cherry-servers.md#set-the-bios).

On another board, inspect its menus and help text; H12/Milan can use different
ASID controls. Do not transplant an H13 key sequence or treat `Auto` as evidence
of enablement. TSME is separate from SMEE. No memory-interleaving change was
needed on the tested boards.

BIOS console setup was manual. The tested Redfish BIOS endpoint required a licence.
Settings survived the Kata reboot, but must be verified after each reinstall or
firmware change. Use the [board manual](https://www.supermicro.com/en/support/resources)
and [AMD SEV enablement guide](https://docs.amd.com/v/u/en-US/58207-using-sev-with-amd-epyc-processors)
for the actual model.

## Review firmware security

Check the delivered model's vendor advisories and running firmware/microcode/TCB.
A functional SNP pass does not establish that known vulnerabilities are fixed;
BIOS version numbers cannot be compared across different boards.

An H12SSW-NTR with an EPYC 7313P failed to reserve the RMP table despite saved SNP
settings. An H13SST-G with BIOS 1.6 (on another provider, October 2026) initialized
SNP but lacked published security fixes. Have the provider update or replace such
hardware; this repository does not flash firmware.

## Prove the running host

On a rig ordered with `make order-rig`, run the check from the controller. It runs
the checker on the node's original OS over the pinned SSH connection, after
printing the board, BIOS version and boot mode, and saves the output in
`$COCO_STATE_DIR/evidence`:

```bash
make check-node-snp
```

On other servers, copy the reviewed script to the raw node and run
`sudo bash /path/to/host-snp-check.sh`.

[The checker](../scripts/host-snp-check.sh) reads module/device/current-boot evidence;
it does not load modules or change firmware. Require `sev_snp=Y`, `/dev/sev`,
readable initialization logs, SNP API and initialized full-memory RMP evidence.
Retain its exit status and complete output with machine identity.

An unloaded `kvm_amd` module or missing SNP parameter needs kernel/module diagnosis.
A disabled parameter needs module-option, command-line and initialization-log checks.
A PSP error code alone does not uniquely identify a BIOS fix.

`bash ansible/up.sh --mode fresh-install` runs these checks again before it asks
to erase the node, and stops on any failure. `-e confirm_erase=<server ID>` only
answers that question ahead; it does not skip the checks. Repeat under installed
RHCOS and after the Kata rollout, then complete hardware-backed guest proofs.
