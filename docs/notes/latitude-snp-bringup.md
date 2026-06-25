# Proven recipe — SEV-SNP host on Latitude.sh (rung-0, verified 2026-06-25)

Real bare-metal SEV-SNP **host** confirmed working on rented cloud metal. This is the
verify-first gate the whole bare-metal engagement decision rested on.

## Hardware / image (what worked)
- Provider: **Latitude.sh**, plan **`m4-metal-medium`** = AMD **EPYC 9124 (Genoa)**, 16c / 128 GB, NYC, **$1.25/hr hourly**.
- OS: **`ubuntu_26_04_x64_lts`** (native image) → kernel **7.0.0-22-generic**, `CONFIG_KVM_AMD_SEV=y`. No iPXE needed.
- BIOS: **AMI Aptio** (not Supermicro "AMD CBS" naming). Remote access: Latitude **browser IPMI/KVM** via `POST /servers/{id}/remote_access` (returns url + `customer_access` user + rotating password).
- Login user on the native image is **`ubuntu`** (SSH-key only), NOT `root`. Run checks via `sudo`.

## BIOS settings that brought SNP up (AMI Aptio)
Two pages:

**Advanced → CPU Configuration:**
- `SMEE` → **Enabled** (was Auto; fixes "SEV: memory encryption not enabled by BIOS")
- `SNP Memory (RMP Table) Coverage` → **Enabled** (was Auto; builds the RMP table)
- `SEV-ES ASID Space Limit` → **100** (was 1)
- `SEV Control` → Enabled (already was)

**Main → North Bridge Configuration:**
- ⭐ `SEV-SNP Support` → **Enabled** ← **THE actual fix.** On `Auto` it stays OFF.
- `IOMMU` → Enabled (Auto already = Enabled; not the blocker despite the error wording)

## The misleading failure mode (→ defect log)
With everything except `SEV-SNP Support` set, the kernel printed:
```
AMD-Vi: SNP: IOMMU SNP feature not enabled, SNP cannot be supported.
kvm_amd: SEV-SNP disabled (ASIDs 1 - 99)
```
This points at IOMMU, but **IOMMU was fine** — the real cause was `SEV-SNP Support = Auto`.
Setting it to `Enabled` set the IOMMU SNP feature bit and SNP came up. Easy to misdiagnose.

## Reproduce
```bash
cd infra/latitude && terraform apply        # m4-metal-medium / NYC / ubuntu_26_04
# POST /servers/{id}/remote_access -> IPMI console -> reboot -> Del -> set BIOS as above
ssh ubuntu@<ip> 'sudo bash -s' < ../../scripts/host-snp-check.sh   # expect all PASS
terraform destroy                            # stop billing
```

## Scope of this proof
Proves **silicon + provider + Ubuntu kernel** do SNP host. Does NOT prove the **RHCOS**
kernel (the actual deliverable) — that's verified at the OpenShift/SNO phase. The customer's
hardware will also need this same BIOS sequence (note for the customer-scoping list).
