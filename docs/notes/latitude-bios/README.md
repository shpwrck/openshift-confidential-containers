# Latitude SEV-SNP BIOS — screens, exact paths, and the wrong-machine tell

Captured live 2026-07-28 on the node `coco-snp-rig` (`sv_ZWr75ZP9v0A91`). This supersedes the
menu paths in `docs/notes/latitude-snp-bringup.md`, which were recorded on an earlier firmware and
send you to a menu that does not exist on this board.

## The board (check this FIRST)

| | Node (what you want) | Bastion (what you don't) |
|---|---|---|
| Plan | `m4-metal-medium` | `m4-metal-small` |
| Board | **Supermicro H13SST-G** (SP5 / Genoa) | AM5-class board |
| BIOS | 3.0, build 10/04/2024, **AMI 2.22.1285** | **AMI 2.22.1294** (2025) |
| Total Memory (Main tab) | **131072 MB** | 65536 MB |
| CPU module version | — | `ComboAm5Cpu 06` |
| Has SEV/SNP settings? | **Yes** | **No** |

### Wrong-machine tell (this cost a detour on 2026-07-28)
The bastion's BIOS has **no SEV, SNP, SMEE, RMP or ASID options anywhere**, and `F5` keyword
search finds nothing — because it is an AM5 board, not the SP5 Genoa node. If you are hunting for
settings that "should be there" and cannot find them, **you are probably on the bastion.**

Confirm before hunting further:
1. The IPMI URL contains the node's server id — `ipmi-rube-farm-<serverid-lowercase>.ipmi.nyc.lsh.io`.
   Node = `zwr75zp9v0a91`. Bastion = `6b9val4lea7vr`.
2. `Main` tab shows **Supermicro H13SST-G** and **131072 MB**.
3. Cross-check from your workstation: the machine you are in BIOS on will **stop answering SSH**,
   while the other still answers. `ssh rocky@<node-ip> 'true'` succeeding means you are NOT in the
   node's BIOS.
4. `Advanced → CPU Configuration → Module Version: ComboAm5Cpu` means AM5 — the bastion.

## The settings (node, H13SST-G, BIOS 3.0)

**`Advanced → CPU Configuration`** — four of the five live here:

| Setting | Factory value | Required |
|---|---|---|
| `SEV-ES ASID Space Limit` | `1` | **100** |
| `SNP Memory (RMP Table) Coverage` | `[Auto]` | **Enabled** |
| `SMEE` | `[Auto]` | **Enabled** |
| `SEV Control` | `[Enabled]` | Enabled (already correct from factory) |

**`Advanced → NB Configuration`** (page title renders "North Bridge Configuration"):

| Setting | Factory value | Required |
|---|---|---|
| ⭐ `SEV-SNP Support` | `[Auto]` | **Enabled** |
| `IOMMU` | `[Auto]` | Enabled (help text says `Auto = Enabled`; set explicitly to remove doubt) |

Then **`F4` → Save & Exit**. **Reboot, do NOT reinstall** — reinstall wipes the disk and resets BIOS.

## Path corrections vs the old recipe

| Old recipe said | Actually |
|---|---|
| `Main → North Bridge Configuration` | **`Advanced → NB Configuration`** — `Main` holds only date/time + board/memory info |
| (implied one layout for all Latitude AMD metal) | Bastion and node ship **different boards and different AMI builds**; only the node has SEV/SNP |

`Advanced → CPU Configuration` was correct — all four CPU-side settings are exactly where the old
recipe said, with the same names.

## Why `Auto` is not `Enabled`

`SEV-SNP Support = Auto` leaves SNP **off**. With everything else set, the kernel prints:

```
AMD-Vi: SNP: IOMMU SNP feature not enabled, SNP cannot be supported.
kvm_amd: SEV-SNP disabled (ASIDs 1 - 99)
```

That reads like an IOMMU fault, but IOMMU is fine — setting `SEV-SNP Support = Enabled` sets the
IOMMU SNP feature bit too. Do not go chasing IOMMU.

## Verify (do not trust the keystroke)

From the workstation, once the node is back up:

```bash
ssh -i ~/.ssh/id_ed25519 rocky@<node-ip> 'sudo bash -s' < scripts/host-snp-check.sh
```

Expect all 8 checks PASS and `RESULT: SEV-SNP host LIVE`. Before the BIOS change this run reports
`ccp … SEV: memory encryption not enabled by BIOS`, `sev_snp = N`, and no `/dev/sev`.

This check is only possible because the node is provisioned `rocky-10` rather than `ipxe`
(see the runbook decision log) — it is what turns the BIOS step from "acknowledged" into "proven",
and it is the backstop for issue #72.

## Screens

Save the KVM captures here as:

- `img/node-01-main.png` — Main tab: H13SST-G / BIOS 3.0 / 131072 MB
- `img/node-02-advanced.png` — Advanced menu: `CPU Configuration` + `NB Configuration`
- `img/node-03-cpu-configuration.png` — the four CPU-side settings at factory values
- `img/node-04-nb-configuration.png` — `SEV-SNP Support [Auto]` before the change
- `img/node-05-cpu-configuration-set.png` — after: ASID 100, RMP Enabled, SMEE Enabled
- `img/node-06-nb-configuration-set.png` — after: `SEV-SNP Support [Enabled]`
- `img/bastion-01-advanced.png` — the bastion's Advanced menu (no SEV options — the wrong-machine tell)
- `img/bastion-02-cpu-configuration.png` — `ComboAm5Cpu 06`, no SEV settings
