# Provider selection for disconnected AMD validation

Research date: October 8, 2026. Target: OCP 4.20.39, OSC 1.13.1 and Red Hat build of Trustee 1.2.1. These are candidate versions, not a completed deployment. Recheck the live product matrix before installation.

## Decision

**Oracle is excluded at the user's direction. Cherry qualification has moved to a direct, bounded hourly trial without engineering outreach.** The owner's API access and funding enabled account-specific price/stock checks. The 9354P had no stock; a 16-core Genoa candidate in Chicago was allocated instead. The [dated allocation receipt](../validation/cherry-qualification-2026-10-08.json) records the returned EUR0.53/hour rate and the initial four-hour cleanup deadline, subsequently disabled at the owner's direction. No remaining provider has been proven to meet every requirement. Cherry's assisted test-server application remains an option if the self-service trial cannot pass. [Virtualization offering and application](https://www.cherryservers.com/servers-for-virtualization)

The delivered EPYC 9124 has passed the Ubuntu and Agent-live RHCOS SNP/RMP host checks after five saved BIOS changes. Bidirectional private networking and private DNS/NTP/registry TLS passed, mirroring completed, and fresh installation is underway. The Agent-live OS has no public address and its public IPv4/IPv6/DNS probes failed while private registry access succeeded. Installed-node, pod, guest attestation and clean-repeat evidence remain pending. Provider iPXE boot-artifact delivery used a tokenized public helper endpoint; it is a separate preparation dependency from the private OS image-pull path. Azure confidential peer pods are a separate architecture option, pending the user's preference; disconnected OSC 1.13 is Technology Preview. One Cherry node and its helper are allocated; no healthy replacement OpenShift cluster is yet verified. The retired Latitude rig never completed an OpenShift installation; its earlier raw-host checks are not guest attestation evidence.

The OCI assessment and estimate below are retained as research history, not the active deployment plan.

## Comparison

| Candidate | Evidence | Decision |
| --- | --- | --- |
| OCI E5 bare metal | Oracle explicitly documents customer-built SNP guests; Red Hat documents disconnected OCI bare-metal installation; Oracle requires UEFI for the imported Agent image. | Excluded by the user. Exact RHCOS/confidential-mode combination was never validated. |
| AWS AMD metal | Authenticated EC2 metadata in Ohio returned 14 AMD metal types, all legacy BIOS only, including M8a/C8a/R8a. | Fails the documented OSC 1.13 UEFI prerequisite. Do not rent these types for this validation. |
| Cherry Servers EPYC 9354P | Hourly hardware, private VLAN, OOB access, BIOS configuration and assisted test-server application are documented. The allocated 9124 and helper passed prerequisite checks. | Active bounded trial. Installed-node isolation and guest proofs remain required; no provider-enforced public-port isolation is claimed. |
| IBM Classic AMD Milan | UEFI and private-only ordering are documented. BIOS changes require a support case. | Secondary lead; no working SNP firmware evidence or exact qualifying hourly quote established. |
| Vultr EPYC 9255 | BIOS/UEFI/custom ISO controls exist. | SNP remains unproven; its specific NAT-deletion restriction prevents assuming the proposed disconnection procedure works. |
| Azure AMD peer pods | Red Hat documents a disconnected deployment workflow. | Different architecture, and disconnected support in OSC 1.13 is Technology Preview; does not validate local bare-metal Kata. |

## OCI assessment retained for reference

Oracle lists E5/E6 bare-metal shapes as supporting customer-built SEV-SNP guests and customer-operated attestation. Confidential mode must be selected at creation. E3/E4 provide SEV without SNP and are unsuitable substitutes. The confidential-compute OS matrix lists Oracle Linux and Ubuntu, not RHCOS, so the exact product combination remains unqualified. Host memory encryption alone does not prove guest confidentiality. [Oracle confidential-computing matrix](https://docs.oracle.com/en-us/iaas/Content/Compute/References/confidential_compute.htm)

Red Hat's OCP 4.20 OCI procedure covers bare-metal machines, disconnected Agent installation and single-node topology. Oracle's image-import instructions require `UEFI_64` enabled and `BIOS` disabled. These provide a documented installation route without adapting the Latitude PXE flow. [Red Hat OCI installation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_oracle_distributed_cloud/installing-oci-agent-based-installer), [Oracle image preparation](https://docs.oracle.com/en-us/iaas/Content/openshift-on-oci/installing-agent-image-creation.htm)

The launch workflow checks both shape and image compatibility for confidential mode. The generic image capability for AMD SEV is described for VMs; setting it does not independently establish a supported RHCOS bare-metal launch. Resolve this before renting a host. [Instance creation](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/launchinginstance.htm), [Image capabilities](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/configuringimagecapabilities.htm)

Proposed networking: private node/Trustee subnets with no public addresses, Internet/NAT routes or IPv6 escape path; a separate mirror/controller subnet; no forwarding through the mirror. Admit only the required provider services through OCI's service gateway. This is disconnected from the Internet, with explicit cloud-service dependencies. The reference infrastructure includes three load balancers per cluster; retain them in the estimate until a documented simplification is established. [OCI networking](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/overview.htm), [Service gateway](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/servicegateway.htm), [Agent infrastructure](https://docs.oracle.com/en-us/iaas/Content/openshift-on-oci/agent-prereq.htm)

## OCI cost estimate

Public USD pay-as-you-go rates checked October 8, 2026: E5 costs $0.030/OCPU-hour plus $0.002/GB-hour. The fixed 192 OCPUs and 2,304 GB of `BM.Standard.E5.192` therefore cost **$10.368/hour**. Bare metal has a one-hour minimum. This is not an account-specific quote. [Oracle price list](https://www.oracle.com/cloud/price-list/), [Shape sizes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm), [Billing minimum](https://docs.oracle.com/en-us/iaas/releasenotes/changes/20facdce-34bf-4648-a0a7-de5db73657ce/index.htm)

The preferred scenario allows six preparation hours before six metal hours. It includes an E5 Flex mirror/controller (4 OCPUs, 32 GB) and a separate Trustee OpenShift SNO VM (8 OCPUs, 32 GB), each running for 12 hours. Assume 1,000 GB total Balanced boot/block storage, 50 GB Object Storage, and three private load balancers per cluster capped at 100 Mbps. Trustee load balancers run 12 hours; worker load balancers run six hours. The mirror is not a replacement for Trustee's trusted OpenShift environment.

| Component | Estimated USD |
| --- | ---: |
| E5 metal, six hours | 62.21 |
| Mirror/controller, 12 hours | 2.21 |
| Separate Trustee SNO VM, 12 hours | 3.65 |
| Boot/block storage | 0.69 |
| Six load balancers for their respective cluster lifetimes | 1.15 |
| Object Storage | 0.02 |
| DNS, operations and small egress allowance | 2.00 |
| Full test, before tax | **About 72** |
| Separate one-hour metal qualification probe, compute only | **10.37 minimum** |

Plan **$15 for the initial one-hour qualification attempt**, then a **$95 combined planning budget for that probe plus the six-hour test**. The combined estimate before contingency is approximately $82 plus probe ancillary costs. These are estimated run budgets, not provider-enforced spending limits or a promise that installation completes in six hours. Prepare a teardown deadline and stop on the first failed hardware gate. Delays, rebuilds or a changed resource plan require re-estimation.

Storage assumes October's 744 hours for monthly proration; block storage uses $0.0425/GB-month at Balanced performance. Load balancers use $0.0113/base-hour plus $0.0001/Mbps-hour. No free-tier credits or negotiated discounts are assumed. Figures exclude tax and new Red Hat subscription purchases, assume existing eligible entitlements and small diagnostics exports, and require deletion of volumes, image storage and other billable resources. [Pricing API documentation](https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/signingup_topic-Estimating_Costs.htm), [Oracle prices](https://www.oracle.com/cloud/price-list/)

The user's **$150 total cap spans providers**. The prior Latitude rounded-up compute estimate is $15.23, excluding extras and not an invoice. A $95 replacement budget leaves roughly $39.77 for historical extras, tax and cleanup reserve. Reconcile actual charges before launch.

## AWS rejection evidence

After presenting a $0 infrastructure estimate for read-only metadata queries, EC2 `DescribeInstanceTypes` in `us-east-2` returned the following AMD metal types with only `legacy-bios`: `c6a.metal`, `c7a.metal-48xl`, `c8a.metal-24xl`, `c8a.metal-48xl`, `m6a.metal`, `m7a.metal-48xl`, `m8a.metal-24xl`, `m8a.metal-48xl`, `m8azn.metal-12xl`, `m8azn.metal-24xl`, `r6a.metal`, `r7a.metal-48xl`, `r8a.metal-24xl`, `r8a.metal-48xl`. No resources were created. [Sanitized observation](../validation/aws-amd-boot-modes-2026-10-08.json)

AWS documents this field as the supported boot modes; a different AMI cannot add a host-supported mode. OSC 1.13 requires host UEFI. These results rule out the checked types for the documented product path; they do not negate the AWS Ubuntu/custom-stack SNP sample or establish a statement about every future AWS offering. [AWS boot modes](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-type-boot-mode.html), [OSC prerequisites](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_confidential_containers_on_bare-metal_servers/install-cc-overview_metal-cc)

## Fallback details

- **Cherry:** its USD EPYC 9354P configurator showed $1.10/hour for 192 GB RAM and 2 x 1 TB NVMe: $26.40 for 24 hours or $52.80 for 48 hours for the host alone. Mirror, separate Trustee environment, any technician/isolation fees and tax still need quoting. A later October 8 check showed Chicago stock at zero and limited Lithuania/Amsterdam stock; do not assume US availability. The private VLAN shares a physical NIC with public traffic; removal of Internet access before installer boot still needs confirmation. No delivered SNP/RMP guarantee was found. [USD configurator](https://www.cherryservers.com/pricing/dedicated-servers/amd-epyc-9354p?currency=USD), [Private VLAN](https://www.cherryservers.com/knowledge/docs/networking/private-vlan-subnet), [OOB console](https://www.cherryservers.com/knowledge/docs/compute/configuration-management/out-of-band-management-console)
- **IBM:** Classic AMD hardware requires UEFI, and private-only interfaces can be selected at order. The general FAQ says BIOS changes require a support case and restart; self-service firmware updates can take four hours. Firmware SNP readiness and an eligible hourly SKU remain unresolved. [Hardware](https://cloud.ibm.com/docs/bare-metal?topic=bare-metal-about-bm), [Networking](https://cloud.ibm.com/docs/bare-metal?topic=bare-metal-network-options), [BIOS/firmware FAQ](https://cloud.ibm.com/docs/bare-metal?topic=bare-metal-bm-faq)
- **Vultr correction:** a specific FAQ says NAT cannot be deleted while VPC-only instances are attached, contradicting reliance on the generic deletion-effects page. Its billing guide says bare metal is hourly with a one-hour minimum; a historical `invoice_type: monthly` field alone does not imply a monthly commitment. The exact 9255 price and isolated deployment sequence remain unqualified. [NAT restriction](https://docs.vultr.com/support/products/network/why-cant-i-delete-a-nat-gateway-with-vpc-only-instances), [Deletion effects](https://docs.vultr.com/support/products/network/what-happens-if-you-delete-a-nat-gateway), [Billing](https://docs.vultr.com/support/platform/billing/how-am-i-billed-for-my-servers)
- **Azure:** OSC 1.13 lists disconnected CoCo on Azure/ARO as Technology Preview. Peer pods use provider-created confidential VMs rather than local SNP guests on our RHCOS metal node. Treat this as a separate test architecture, not an equivalent replacement. [OSC technology previews](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/release_notes/technology-previews)

ARO egress lockdown proxies required service and system-registry traffic through private endpoints. It does not by itself prove a fresh OpenShift installation using only our private mirror. Self-managed Azure has a mirrored installation path, but its complete private API/authentication dependencies and the proposed small topology still require qualification. Do not silently substitute an ARO private cluster for the original disconnected-install proof. [ARO egress behavior](https://learn.microsoft.com/en-us/azure/openshift/howto-restrict-egress)

## Qualification request retained as a fallback

Request an exact Cherry server/location, current motherboard/BIOS/AGESA/PSP versions, enabled SVM/IOMMU/SMEE/SNP with usable RMP, and preferably a verified guest report. Confirm UEFI custom RHCOS boot and working OOB, plus provider-enforced IPv4/IPv6 Internet isolation before installer boot while retaining mirror/DNS/NTP and management access. Obtain a complete hourly quote, minimum billing, preparation fees, and the handling of a server that fails the agreed checks. Include the mirror and separate Trustee cluster in that quote. No request has been submitted.

The active hourly two-server trial has a conservative catalogue rate of €1.22/hour before extras and an initial four-hour deadline, subsequently disabled at the owner's direction; its allocated total rate is €1.06/hour. The existing $150 combined cap still applies. The current trial uses OS/private-network isolation, with provider port enforcement unproven. If its remaining checks fail, preserve the evidence and retire the exact task resources; do not spend on speculative replacements.

## Historical OCI qualification sequence

1. Obtain an approved OCI tenancy/compartment and region; check permissions, quota, capacity and image compatibility without launching compute. Price any image import/storage separately before creating it.
2. Resolve confidential-mode eligibility for the exact custom RHCOS image. If documentation and metadata cannot settle it, prepare a precise vendor clarification for the user; no outreach is currently authorized.
3. Prepare the mirror and rootfs, separate Trustee environment, private routing, admitted cloud APIs and complete teardown. Review the concrete resource estimate before rental.
4. Run one bounded hardware test: actual UEFI, usable RMP/SNP initialization and a verified guest report. Stock RHCOS/OSC must pass; a successful Ubuntu replacement is insufficient.
5. Install from the first boot with Internet egress denied. Verify host/pod/guest denial and private service access, attestation and secret release, deliberate policy rejection, workload rungs and reboot recovery.

No provider has yet passed this complete sequence in this run. The initial public-source research made no allocations or outreach; the subsequent authorized Cherry trial allocated one node and helper, passed prerequisite checks and started installation, with full acceptance pending.
