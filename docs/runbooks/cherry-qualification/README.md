---
leave-behind: v1
state-scope: cherry-qualification
status: current
---

# Cherry qualification leave-behind

## Operability

### State and access

This is a temporary paid qualification rig, not a deployed OpenShift cluster. On October 8, 2026, task project 295533 (`coco-qualification-20261008`) owns server 1025551 (`coco-snp-chicago-20261008`) in US-Chicago and SSH key 19635. The pre-existing project 295530 is outside this scope. Resolve current addresses through the provider API before access; never reconnect to a released address.

Private control state, SSH key, known-hosts file, console credentials and raw evidence live outside the checkout at `/home/jskrzypek/.local/state/openshift-confidential-containers/cherry/trial/`. The provider API credential is supplied as `CHERRY_SERVERS_API_KEY` by the user's interactive shell. Never copy credential values into this repository. The private README and `control.py` contain the exact current access and retirement commands.

### Template map

scripts/host-snp-check.sh -> read-only SSH stdin execution on task server 1025551

Private trial/control.py -> task provider objects recorded in private trial/state.json

Private trial/preflight-host.sh -> private trial/raw-preflight-after-bios.txt

### Re-run

Do not rerun allocation to reproduce a BIOS check. On the currently owned node, inspect firmware under Advanced → CPU Configuration and Advanced → NB Configuration. The saved settings are SMEE Enabled, SNP Memory (RMP Table) Coverage Enabled for all system memory, SEV-ES ASID Space Limit 100, IOMMU Enabled and SEV-SNP Support Enabled. SVM Mode and SEV Control were already Enabled. No firmware flash, defaults reset, interleaving change or boot-order change was performed.

Run the repository's `scripts/host-snp-check.sh` through the task SSH connection, then the independently digest-verified `snphost` 0.7.0 binary's `ok` command. Recheck after reprovisioning and under RHCOS; this Ubuntu result is not an OpenShift result.

### Verify and recover

Verified October 8, 2026: EPYC 9124, H13SST-G, BIOS 3.7 built January 23, 2026, Ubuntu 26.04.1, kernel 7.0.0-34-generic and UEFI boot. Both host checks exited zero after the five BIOS changes. `/dev/sev` is present, `sev_snp=Y`, RMP range is `0x88200000–0x987fffff`, and SEV-SNP API is 1.58 build 2. `snphost` reported RMP initialized, no aliasing addresses, and matching platform/reported TCB values. Retain initial failure evidence: Auto settings produced memory encryption disabled, missing `/dev/sev` and SNP disabled.

Private networking, internet isolation, guest attestation and fresh disconnected OpenShift installation remain unproven. Initial cloud-init also reported recoverable network wait/rename warnings; derive NIC names from the actual host before configuration.

The mandatory retirement deadline is **2026-10-08 19:38:10 UTC (3:38 p.m. EDT)**. The local `coco-cherry-budget.timer` runs the private controller's `guard` every minute. WSL must remain running; this is not a provider-side spending cap. For early retirement, run the private controller's `cleanup-plan`, then `cleanup` through an interactive shell that loads the API key. Confirm each owned server, SSH key and project returns absence. Preserve diagnostics, remove the task timer/service after retirement, and retain pre-existing account resources. Actual deletion has not yet been exercised for this trial.

## Decision log

### Decisions

Use one hourly Genoa node to prove the firmware prerequisite before renting a helper. The allocated rate is €0.53/hour before extras; four-hour host estimate €2.12. The qualification ceiling is $20 within the overall $150 infrastructure cap. Do not silently extend the four-hour window.

The included HTML5 BMC console allowed BIOS configuration without engineering assistance. The licensed Redfish BIOS endpoint rejected reads; no licence was purchased and no licensed gate was bypassed. One-time `systemctl reboot --firmware-setup` entered Setup after establishing the graphical console.

### How to drive it

Check the deadline and provider ownership first. Preserve the successful raw-host evidence in [the sanitized qualification receipt](../../validation/cherry-qualification-2026-10-08.json). Next obtain a current helper quote, prove bidirectional private connectivity and establish an isolation method before attempting the disconnected installation. Repeat SNP checks on the actual RHCOS worker, then prove guest launch and attestation. Retire early if a required provider control is unavailable; update this runbook to retired after confirmed deletion.
