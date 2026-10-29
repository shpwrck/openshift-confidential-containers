# Validation results

What has been tested, when and on what. Read this before you rely on a claim
elsewhere. Nothing here is a live environment: every rig was deleted after its run.

## Runs

| Date | Rig (Cherry Servers) | How it ran | Result |
|---|---|---|---|
| **October 29, 2026** | AMD EPYC 9124 node, Intel Xeon Gold 6330 helper, US-Chicago | A fresh run from these docs only, with the one-command steps of the [quickstart](quickstart.md) | All six tests passed, then passed again after `make reset-lab` and a CoCo reinstall. Rig deleted. |
| October 28, 2026 | AMD EPYC 9254 node, Intel Xeon Gold 6330 helper, US-Chicago | From the docs by hand; each gap found was fixed in the repository | The five CPU tests and isolation passed twice, with a reset between. Rig deleted. |
| October 8, 2026 | AMD EPYC 9124 node, AlmaLinux 9.8 helper | The first trial | The five CPU tests and isolation passed twice, with a clean CoCo reinstall between. Rig deleted. |

All three runs used the same release and the same layout: single-node OpenShift
with Trustee on the same cluster, in the Permissive profile over HTTP, with the
restrictive resource policy enforcing.

## Tested release and hardware

| Component | Version |
|---|---|
| OpenShift | 4.20.39 (exact payload in the [release manifest](../install/release-manifest.json)); RHCOS 9.6.20260914-0, kernel 5.14.0-570.141.1.el9_6 |
| OSC / Trustee | 1.13.1 / 1.2.1 |
| NFD / cert-manager / Gatekeeper | 4.20.0-202609201357 / 1.20.1 / 3.21.1 |
| Mirror registry / coco-tools | 2.0.12 / 0.5.1 |
| Node | Supermicro H13SST-G, BIOS 3.7, UEFI, with an EPYC 9124 or 9254 |
| Helper | AlmaLinux 9. Cherry offers no RHEL image; Red Hat supports the mirror registry on RHEL only. |

The plans that passed are in [`infra/cherry/tested-plans.json`](../infra/cherry/tested-plans.json);
`make order-rig` offers them first.

## What the tests showed

| Test | Shown on the rig |
|---|---|
| `rung-kbs` | The workload's secret only reaches it inside the confidential runtime. |
| `rung-initdata` | Trustee refuses a VM whose initdata changed by one comment. |
| `rung-rvps` | Trustee refuses a VM when the approved launch measurement is removed. |
| `rung-signed` | The VM pulls a signed image and refuses an unsigned one under the same key policy. |
| `air-gap` | Trustee refuses a VM when the node's AMD certificate (VCEK) is replaced with a wrong one. |
| `isolation` | The node, an ordinary pod and a confidential VM reach the private registry but no public address or name, and `oc exec` into the VM is refused. |

Each test passed its allow, deny, restore and recovery controls. A denial only
counted when Trustee logged a matching refusal for that VM. [Capability tests](capability-status.md)
describes the controls.

The SEV-SNP host check passed on every node before its install; in the first trial
it also passed in the installer environment, on the installed node and after the
Kata rollout. The cluster checks passed each time, and `kata-cc` used the
`kata-snp` handler.

## Timing on October 29

| Step | Time |
|---|---|
| Order the rig | 1 h 45 min, of which 60 min was a helper Cherry was slow to deliver; the node took 15 min |
| Prepare the helper and mirror | 27 min |
| Install OpenShift | 47 min from the reinstall request |
| Install the CoCo Operators | 18 min, and 16 min in round 2 |
| Set up Trustee | 3 min, and 2 min in round 2 |
| Capability tests | 23 min each round |
| Reset the lab | 10 min |
| Delete the rig | under 1 min |

The controller restarted in the middle of the install. `bash ansible/up.sh --mode resume-install`
finished it without a second reinstall.

## Limits

- Trustee ran on the same cluster in the **Permissive profile over HTTP**. A
  separate Trustee cluster, Restricted HTTPS mode, a customer agent policy, HA/DR
  and upgrades were not tested on hardware.
- The first boot of the node used a public, token-protected URL on the helper.
  Isolation held from the installer environment onward; a fully private boot from
  power-on was not tested.
- Encrypted images and Artifactory were not tested. Intel and GPU configurations
  are out of scope.
- Using AlmaLinux on the helper does not establish Red Hat support for that choice.

## Evidence

Each run writes its own evidence outside the checkout, in `COCO_STATE_DIR`: the
host checks in `evidence/` and one report per test run in `proofs/<run>/results.json`
(release identities, policy hashes, pod UIDs and the result of every control).
Reports hold no credentials. Raw logs, credentials and installer assets are never
committed, and no run's evidence is part of this repository; a new run needs new
inputs and produces its own.

## Provider history

An attempt on Latitude.sh (October 5, 2026) stopped before the install: its private
network could not meet the isolation requirement. Cherry Servers' private VLAN
with LACP bonding did. AWS bare-metal AMD instances were ruled out because they
offered only legacy BIOS boot, and OSC 1.13 requires UEFI.
