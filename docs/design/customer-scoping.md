# Customer deployment and upgrade planning

The repository has validated a disposable AMD SNO lab. Customer installation,
Restricted HTTPS in a separate Trustee trust domain, HA/DR and upgrades need
validation in the customer's environment. [The trial record](../validation/README.md)
states the demonstrated scope.

## Confirm before deployment

| Area | Information to collect |
|---|---|
| Product support | Exact OCP/OSC/Trustee versions, dated live compatibility matrix, entitlements and supported update path |
| Hardware | Actual CPU/board/BIOS/BMC, UEFI, initialized SNP/RMP, firmware fixes and eligible worker pool |
| Private network | Registry, DNS/NTP, TLS/authentication, mirror paths, boot delivery and isolation at host/pod/guest levels |
| Trustee | Separate trust domain/context, endpoint TLS and token signer, administrator access, policies, resources and storage |
| Workloads | Protected resource paths, complete agent policy, approved image digests/signatures, memory requirements and negative controls |
| Operations | Owners, monitoring, reference/certificate expiry, backups, tested recovery and rollback checkpoints |

Start with [firmware preflight](../amd-firmware-preflight.md),
[Trustee setup](../trustee-current.md) and [guest registry access](../guest-images.md).
BIOS automation depends on the actual vendor/BMC; manual setup was required in the lab.

## Existing OSC 1.12 / Trustee 1.1 deployments

Treat this as a product migration, not the provider fresh-install path:

1. Capture the current cluster IDs, OCP payload, CSVs/CRDs, Trustee ownership,
   policies, resources, VCEKs, TLS/signing identities and storage in protected backups.
2. Check the **live OSC 1.12 matrix** for the existing baseline and the target
   **OSC 1.13 matrix**. Verify the customer's actual OCP update graph;
   the tested 4.20.39 target does not prove an update edge from 4.20.18.
3. Follow the product update order and rehearse Trustee migration in an isolated clone.
   Trustee 1.2 can replace policy/configuration maps and does not preserve every custom
   verifier setting. The repository refuses automatic adoption of standalone KbsConfig.
4. Recalculate launch references and approved hardware TCB, recollect collateral when
   needed, and rebind final initdata. Run the affected positive/negative/recovery proofs.
5. Verify serving configuration, workload health and network isolation after rollouts.
   Rollback must restore compatible software, policy, references, collateral and signer
   identities together; a policy-only rollback is insufficient.

Use Red Hat's [OSC update procedure](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/update-osc-cc-overview_metal-cc)
and [Trustee product guide](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers/index).
[The existing 1.12 compatibility matrix](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/cc-discover_metal-cc)
and [target 1.13 matrix](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/cc-discover_metal-cc)
are separate checks. Recheck them before customer use; a dated repository manifest
cannot replace live support guidance.

## Changes after deployment

Reassess references and rerun affected proofs after firmware, guest artifacts,
initdata, agent/resource/image policies or signing identities change. Track expiry
and refresh before it blocks attestation. [Maintenance](../maintenance.md) maps the
repository helpers; it does not provide a production backup or rotation service.
