# Architecture

A confidential pod runs inside its own small VM on the AMD node. SEV-SNP encrypts
that VM's memory so the host cannot read it. The VM starts without its secrets:
it has to prove to Trustee what hardware and software it is running before
Trustee releases anything, including the credentials it needs to pull its own
container image. This page shows that exchange, the components involved, the
test rig the automation builds, and the order of the install and the tests.

## How a confidential pod gets its secrets

```mermaid
sequenceDiagram
  autonumber
  participant K as Kubelet and CRI-O on the AMD node
  participant G as Pod VM (guest components)
  participant KBS as Trustee Key Broker Service
  participant AS as Attestation service and RVPS
  participant R as Mirror registry
  K->>G: Start the pod as an SEV-SNP VM (runtime class kata-cc)
  Note over K,G: The initdata hash is measured into the VM's launch report
  G->>KBS: Request a resource, such as registry credentials
  KBS-->>G: Challenge
  G->>KBS: Hardware-signed attestation report and initdata
  KBS->>AS: Verify the evidence
  Note over AS: Chip certificate (VCEK) from the offline cache,<br/>launch measurement and firmware levels from RVPS,<br/>initdata hash from the CPU policy
  AS-->>KBS: Signed result of each check
  Note over KBS: The resource policy decides and denies by default
  KBS-->>G: Resource, encrypted to a key only this VM holds
  G->>R: Pull the workload image inside the VM
  Note over G,R: Credentials, mirror remaps, registry CA and<br/>signature policy all come from Trustee
  G->>G: Start the workload container
```

Each [capability test](capability-status.md) changes one input in this exchange
(the initdata, a reference value, the image signature or the VCEK) and checks
that Trustee then refuses the request.

## Components and trust domains

```mermaid
flowchart LR
  Sources[Connected artifact and VCEK preparation] --> Mirror[Private image registry]
  Sources --> Collateral[Offline endorsement collateral]
  subgraph Workers[Worker trust domain]
    Host[RHCOS and Kata] --> Guest[Confidential pod VM]
    Guest --> Agents[Attestation agent and data hub]
  end
  subgraph Trust[Separate customer Trustee trust domain]
    KBS[Key Broker Service] --> AS[Attestation service]
    AS --> Refs[Approved launch and hardware references]
    AS --> Collateral
  end
  Guest -->|Guest image pull| Mirror
  Agents -->|Evidence over HTTPS| KBS
  KBS -->|Policy-approved resources| Agents
```

`WORKER_CONTEXT` and `TRUSTEE_CONTEXT` select the two domains independently, so
the scripts can drive a worker cluster and a separate Trustee cluster. `kata-cc`
must resolve to the `kata-snp` handler. The completed trial used a simpler
layout: Trustee on the same cluster in the Permissive profile over HTTP. The
separate customer boundary drawn here has not been validated on hardware; see
[validation results](validation.md).

## The test rig

```mermaid
flowchart LR
  subgraph Internet
    RH[Red Hat and Quay registries]
    API[Cherry Servers API]
  end
  Controller[Controller: Ansible and scripts]
  subgraph Helper[Helper server]
    Reg[Mirror registry :8443]
    DNSNTP[DNS and NTP]
    Boot[Boot files :8080 behind a random URL token]
    Console[Optional console proxy]
  end
  subgraph Node[AMD SEV-SNP node]
    OCP[Single-node OpenShift with Kata, OSC and Trustee]
  end
  Controller -->|SSH| Helper
  Controller -->|Discovery and reinstall| API
  Controller -.->|SSH to the original OS, before install only| Node
  Helper -->|oc-mirror pulls release content| RH
  Node -.->|First iPXE boot only, public IP| Boot
  OCP -->|Private VLAN: images, DNS, time| Reg
  OCP --> DNSNTP
  Console -->|Private VLAN| OCP
```

The node and the helper share a private VLAN (`192.168.66.0/24` by default, set in
[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml)). The node's bonded
network has no public address once OpenShift is installed: it reaches only the
helper's registry, DNS and NTP. The helper keeps its public interface to stage
content and serve the first boot, but does not forward traffic from the VLAN to
the internet. The cluster API is only on the VLAN, so the controller reaches it
through the helper (for example, an SSH tunnel). The optional `gitops/base/airgap-egress`
MachineConfig adds a host egress filter on the node.

## Install sequence

```mermaid
flowchart TD
  Inventory[Resolve release inventory] --> Hardware[Verify actual hardware, UEFI and SNP]
  Hardware --> Helper[Prepare mirror, private DNS and NTP]
  Helper --> Link{Raw node private-service checks pass?}
  Link -->|No| Diagnose[Keep provider OS and diagnose networking]
  Diagnose --> Link
  Link -->|Yes| Install[Explicit fresh OpenShift install]
  Install --> Platform[Verify payload, health, installed SNP and isolation]
  Platform --> Operators[Install checked Operators and scoped Kata runtime]
  Operators --> Trustee[Bootstrap Trustee and offline collateral]
  Trustee --> Policy[Calculate references and publish reviewed policies]
  Policy --> Proof[Run five CPU proofs and network controls]
  Proof --> Repeat[Remove and reinstall CoCo software; repeat proofs]
```

A fresh install replaces the node's operating system; it is not an upgrade path
for an existing cluster. A successful install also stops serving the boot files.
The [quickstart](quickstart.md) walks through these steps, and
[the Ansible README](../ansible/README.md) shows which playbook phase does what.

## Capability test sequence

```mermaid
flowchart TD
  Gate[Check inputs and lock Trustee namespace] --> Allow[Positive workload succeeds]
  Allow --> Deny[Change one input and require attributable denial]
  Deny --> Restore[Delete denied pod and restore exact configuration]
  Restore --> Ready[Verify refreshed serving pods]
  Ready --> Recover[Recovery workload succeeds]
  Recover --> Cleanup[Verify cleanup, release lock and record result]
```

A denial only counts when Trustee logs a matching, specific refusal for that VM.
Unrelated errors (DNS, registry, a missing image) and skipped steps cannot pass.
If restoring the configuration fails, the runner keeps the recovery files and the
lock so you can inspect them. [Capability tests](capability-status.md) define each
negative control; [customer planning](customer-planning.md) covers deployment and
upgrade decisions.
