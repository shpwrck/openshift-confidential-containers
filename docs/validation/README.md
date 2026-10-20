# Validation results

**Validated October 8, 2026. Both Cherry servers and their project and SSH key have since been deleted.**
This page summarizes the dated receipts. It does not reverify a live environment.

## Tested release and environment

| Component | Observed version |
|---|---|
| OpenShift | 4.20.39, exact payload in the [manifest](../../install/release-manifest.json) |
| OSC / Trustee | 1.13.1 / 1.2.1 |
| NFD | 4.20.0-202609201357 |
| cert-manager / Gatekeeper | 1.20.1 / 3.21.1 |
| Registry / coco-tools | mirror-registry 2.0.12 / 0.5.1 |
| Node | AMD EPYC 9124, H13SST-G, BIOS 3.7, UEFI |
| Installed OS | RHCOS 9.6.20260914-0, kernel 5.14.0-570.141.1.el9_6 |

All 34 core ClusterOperators were healthy, the node and MachineConfigPool converged,
and all five selected Operator CSVs succeeded. `kata-cc` used handler `kata-snp`.
Raw-host, Agent-live, installed-node and post-Kata SNP checks passed.

## Results

| Check | Outcome and receipt |
|---|---|
| Release identities and mirror selection | Authenticated catalog/bundle/image resolution and oc-mirror dry run passed. [Artifact record](release-resolution-2026-10-05.json) |
| Fresh OpenShift platform and runtime | Exact payload, Operator versions, offline guest attestation and isolation passed. [Platform record](cherry-qualification-2026-10-08.json) |
| Five CPU capability proofs | Secret gate, initdata tamper, actual RVPS launch-reference removal, signed/unsigned images and wrong-VCEK denial each passed allow/deny/recovery. [Proof record](cherry-cpu-proofs-2026-10-08.json) |
| Clean CoCo software repeat | Removed and recreated six Operator/operand namespaces, reinstalled CoCo and reran all five proofs plus isolation without manual repairs in the passing attempt. [Repeat record](cherry-software-repeat-2026-10-08.json) |
| Retirement | Fresh provider GETs confirmed both servers, task SSH key and task project absent; protected backup verified. [Retirement record](cherry-retirement-2026-10-08.json) |

The software repeat used source `d5915bda5c9e43edfcfa599b837a22a9cbe30e1f`.
It retained OpenShift, the mirror and physical allocations; it was not a second
full infrastructure or OpenShift installation. Earlier failed attempts remain in
protected evidence. One boot recorded a 60-second NetworkManager wait timeout,
followed by normal CRI-O/kubelet/API recovery; its cause was not established.

Fresh host, ordinary-pod and confidential-guest TCP/DNS probes found public egress
blocked while private registry TLS worked. A guest probe calibration correctly
failed against a reachable private destination. Guest administrator exec remained
denied. Network isolation is separate from the wrong-VCEK attestation test.

## Limits

- Trustee was a co-located **Permissive HTTP lab**, with the vendor restrictive EAR
  resource policy enforcing hardware, launch and configuration appraisals. Separate
  customer Trustee, Restricted HTTPS, customer agent policy, HA/DR and upgrades were not validated.
- Initial iPXE boot delivery used a public tokenized endpoint. Isolation passed
  from the private Agent OS onward; private delivery from power-on was not tested.
- Encrypted images were not tested. Intel and GPU configurations are outside this AMD CPU scope.
- AlmaLinux on the helper does not establish Red Hat support for that host choice.

## Preserved evidence

The JSON receipts in this directory contain identifiers, hashes and outcomes.
Raw logs, credentials, installer assets and proof recovery files were never
committed, and the private backup of the trial is not part of this repository.
A new run needs new inputs and produces its own evidence.

## Provider history

An earlier attempt on Latitude.sh (October 5, 2026) was abandoned before an
OpenShift install because its private network could not meet the isolation
requirement. Cherry Servers' private VLAN with LACP bonding did. AWS bare-metal
AMD instance types were ruled out because they only offered legacy BIOS boot,
and OSC 1.13 requires UEFI; see the [AWS boot-mode check](aws-amd-boot-modes-2026-10-08.json).
