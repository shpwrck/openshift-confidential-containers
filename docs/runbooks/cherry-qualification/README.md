---
leave-behind: v1
state-scope: cherry-qualification
status: current
---

# Cherry trial leave-behind

## Operability

### State and access

**Retired October 8, 2026, at 20:36 EDT.** Fresh provider reads confirmed node
1025551, helper 1025601, task SSH key 19635 and task project 295533 absent.
Pre-existing project 295530 was preserved. [Retirement receipt](../../validation/cherry-retirement-2026-10-08.json).
There is no live cluster or SSH/API endpoint to operate.

Protected controller state is
`/home/jskrzypek/.local/state/openshift-confidential-containers/cherry/trial/`.
It retains ownership records, historical inputs, kubeconfigs and evidence.
Do not replay retired addresses, host keys, boot tokens or provider IDs for a new allocation.
The API tunnel is closed; controller `coco-cherry-budget` timer/service remain masked
and inactive. Do not rearm the retired trial's timer.

### Template map

ansible/roles/render_configs/templates/agent-config.yaml.j2 -> former helper /opt/install/cluster-assets/agent-config.yaml

ansible/roles/bastion_isolation/templates/bastion-isolation.sh.j2 -> former helper /usr/local/sbin/coco-bastion-isolation.sh

scripts/apply-trustee.sh -> Operator-owned Trustee configuration and checked serving pods

scripts/run-proofs.py -> protected deployment/proofs/<run>/results.json and recovery evidence

### Re-run

A future trial needs new authorized allocations, budget, pinned access, actual
hardware/NIC/disk facts and fresh external inputs. Provision Cherry manually,
complete the [firmware gate](../../amd-firmware-preflight.md), then follow
[Cherry setup](../../cherry-validation.md) and [the quickstart](../../current-quickstart.md).
Provisioning is manual; the repository prepares and installs supplied servers.

The tested node was EPYC 9124 / H13SST-G / BIOS 3.7 with UEFI. Manual console setup
enabled SMEE, full-memory RMP, IOMMU and SNP, with SEV-ES ASID limit 100.
Recheck saved settings and running SNP after changes; these values are not a
universal recipe for other boards.

The lab used co-located `TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1` with the vendor
restrictive EAR resource policy. Recalculate launch references from selected artifacts
and the exact command line, add approved hardware TCB values and bind initdata separately.
[Trustee setup](../../trustee-current.md) describes the required order.

### Verify and recover

[Validation results](../../validation/README.md) link the platform, five CPU proofs,
clean software repeat and retirement receipts. Hardware SNP, exact OCP/Operator/runtime
identities, private-service controls and host/pod/guest isolation passed before retirement.
The repeat recreated CoCo software on the existing platform; it did not reinstall
OpenShift or allocate a second infrastructure set.

The verified final archive is `pre-retirement/helper-recovery.tar.gz` under the
protected controller state: 612 files, 1,462,862,564 bytes. SHA-256:
`737f005aa23ae5a46901e4ccf0d0a4381d59477d7525fa668e8a654a7358a1df`.
`pre-retirement/recovery-verification.json` records member/hash checks.

It preserves original signed/unsigned/signature artifacts, signing identity/password,
mirror CA/server keys and configuration, final Trustee/platform snapshots, installer
assets and complete proof/attempt evidence. It excludes registry image cache, Quay DB,
Python environment and a full etcd restore proof. Never publish it. Restore only into
protected storage and reconstruct the excluded services deliberately.

For an interrupted future proof, inspect recovery files, object versions and the
namespace lock before modifying them. Verify restored configuration is served by new
Ready pods before recovery. Do not clear locks/finalizers blindly or reuse a historical PASS.

## Decision log

### Decisions

Cherry's private VLAN/LACP path met the requirement that failed at Latitude. Manual
BIOS setup was accepted. Connected preparation and public tokenized iPXE delivery were
separate from private Agent/RHCOS/pod/guest operation; fully private power-on boot remains unproved.

Live repairs addressed mirror TLS/bootstrap, API DNS, OLM bundle provenance,
accepted-request resume, Trustee pod refresh, exact launch calculation and attributable
denials. The passing software repeat needed no manual repairs. Customer Restricted HTTPS,
a separate Trustee trust domain, customer upgrades and encryption remain unvalidated.

### How to drive it

The owner ended experiments and authorized retirement after backups, checks and PR
creation. Preserve the protected archive and dated receipts. There is no remaining
cloud action for this rig. For a new run, start with fresh identity/network/collateral
inputs, record each checkpoint and failed attempt, and update this state record only
when new infrastructure is actually verified. Documentation edits do not change the
October 8 verification date.
