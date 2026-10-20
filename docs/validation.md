# Validation results

This page records what has actually been tested, when, and on what. Read it
before you rely on a claim elsewhere in the repository. Nothing here is a live
environment: the hardware used for the trial was deleted after it passed.

## Summary

| | |
|---|---|
| Last hardware validation | October 8, 2026, on Cherry Servers bare metal |
| Release tested | OpenShift 4.20.39, OSC 1.13.1, Trustee 1.2.1 (the pins in the [release manifest](../install/release-manifest.json)) |
| Topology | Single-node OpenShift with Trustee on the same cluster, Permissive profile over HTTP |
| Passed | Fresh install, all five CPU capability tests, network isolation, and the same tests again after removing and reinstalling the CoCo software |
| Not tested | Encrypted images, Trustee in a separate cluster, Restricted (HTTPS) Trustee on hardware, upgrades, private boot from power-on |

## Tested release and environment

| Component | Observed version |
|---|---|
| OpenShift | 4.20.39, exact payload in the [manifest](../install/release-manifest.json) |
| OSC / Trustee | 1.13.1 / 1.2.1 |
| NFD | 4.20.0-202609201357 |
| cert-manager / Gatekeeper | 1.20.1 / 3.21.1 |
| Registry / coco-tools | mirror-registry 2.0.12 / 0.5.1 |
| Node | AMD EPYC 9124, Supermicro H13SST-G, BIOS 3.7, UEFI |
| Installed OS | RHCOS 9.6.20260914-0, kernel 5.14.0-570.141.1.el9_6 |
| Helper | AlmaLinux 9.8 (a compatibility test; Red Hat supports RHEL for the mirror registry) |

All 34 core ClusterOperators were healthy, the node and MachineConfigPool converged,
and all five selected Operator CSVs succeeded. `kata-cc` used handler `kata-snp`.
SEV-SNP checks passed on the provider's original OS, in the installer environment,
on the installed node and after the Kata rollout.

## Results

| Check | Outcome |
|---|---|
| Release identities and mirror selection (October 5) | Authenticated catalog, bundle and image resolution and an oc-mirror dry run passed. |
| Fresh OpenShift platform and runtime | Exact payload, Operator versions, offline guest attestation and isolation passed. |
| Five CPU capability tests | Secret gate, initdata tamper, launch-reference removal from RVPS, signed versus unsigned images, and wrong-VCEK denial each passed allow, deny and recovery. See [capability tests](capability-status.md). |
| Clean CoCo software repeat | Removed and recreated six Operator and operand namespaces, reinstalled CoCo and reran all five tests plus isolation without manual repairs. |
| Retirement | Fresh provider reads confirmed both servers, the SSH key and the project were deleted. |

The software repeat used source commit `d5915bda5c9e43edfcfa599b837a22a9cbe30e1f`.
It kept OpenShift, the mirror and the servers; it was not a second full install.
One boot recorded a 60-second NetworkManager wait timeout followed by normal
CRI-O, kubelet and API recovery; its cause was not established.

Fresh host, ordinary-pod and confidential-guest TCP and DNS probes found public
egress blocked while private registry TLS worked. A deliberately reachable private
destination confirmed the guest probe could detect a working path. Administrator
exec into the guest stayed denied. Network isolation is a separate check from the
wrong-VCEK attestation test.

## Limits

- Trustee ran on the same cluster in the **Permissive profile over HTTP**, with the
  vendor's restrictive resource policy enforcing hardware, launch and configuration
  checks. A separate Trustee cluster, Restricted HTTPS mode, a customer agent policy,
  HA/DR and upgrades were not validated on hardware.
- The first iPXE boot used a public, token-protected URL on the helper. Isolation
  passed from the installer environment onward; private boot from power-on was not tested.
- Encrypted images were not tested. Intel and GPU configurations are out of scope.
- Using AlmaLinux on the helper does not establish Red Hat support for that choice.

## Raw records

The trial's machine-readable records (identifiers, hashes and outcomes, no
credentials) were removed from the working tree on October 20, 2026 to keep the
repository current. They remain in Git history:

```bash
git show 62d59de:docs/validation/                         # list the records
git show 62d59de:docs/validation/cherry-cpu-proofs-2026-10-08.json
```

| Record | Contents |
|---|---|
| `release-resolution-2026-10-05.json` | Catalog, bundle and image resolution behind the release manifest |
| `cherry-qualification-2026-10-08.json` | Platform install and hardware qualification |
| `cherry-cpu-proofs-2026-10-08.json` | The five capability tests |
| `cherry-software-repeat-2026-10-08.json` | The clean CoCo software repeat |
| `cherry-retirement-2026-10-08.json` | Teardown and backup confirmation |
| `aws-amd-boot-modes-2026-10-08.json` | Why AWS bare metal was ruled out |

Raw logs, credentials, installer assets and recovery files were never committed,
and the private backup of the trial is not part of this repository. A new run
needs new inputs and produces its own evidence outside the checkout.

## Provider history

An earlier attempt on Latitude.sh (October 5, 2026) was abandoned before an
OpenShift install because its private network could not meet the isolation
requirement. Cherry Servers' private VLAN with LACP bonding did. AWS bare-metal
AMD instance types were ruled out because they only offered legacy BIOS boot,
and OSC 1.13 requires UEFI.
