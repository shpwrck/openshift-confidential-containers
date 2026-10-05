# Latitude.sh bastion — persistent air-gap mirror host

The **long-lived** half of the rig. Stands up the disconnected-install support infrastructure
once, so the disposable SNP node (`../`) can be cycled underneath it freely:

- a **private virtual network** (VLAN) with real **L3** (static private IPs assigned in cloud-init),
- a **bastion** bare-metal host running Red Hat **`mirror-registry`** (quay) under a **DNS name
  mapped to its private IP**, so the node's pull validates the cert SAN (no `x509` IP-SAN failure),
- a **firewall API object** the SNP node can reference; enforcement needs separate validation.

## Why separate from the node module

Mirroring time depends on the selected inventory and network, and its workspace is **cacheable**. This module keeps the mirror
workspace on the bastion's own disk (`mirror_root`, default `/opt/mirror`), so:

> **Apply the bastion once → re-provision the SNP node as many times as you like → pay the
> mirror cost once.** Destroying the node with its external state preserves the mirror;
> use the [external-state teardown procedure](../../../docs/latitude-validation.md#close-the-endpoint-and-tear-down).

Different state, different lifecycle. **Apply this module before enabling `air_gap=true`** —
the node module then reads its outputs (`virtual_network_id`, `firewall_id`) via
`terraform_remote_state`. A standalone node with `air_gap=false` can be screened for
hardware compatibility first; the accepted node and bastion must be in the same site.

## Registry and host prerequisites

The bastion defaults to **Rocky Linux 9 as a compatible lab baseline**, subject to live
validation on the selected Latitude plan. Red Hat's [mirror-registry prerequisites](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/installing-mirroring-creating-registry)
specify **RHEL 8 or 9**, Podman 3.4.2 or later, OpenSSL, DNS and SSH connectivity. Rocky
does not inherit Red Hat host support. This bastion choice does not change the disposable
SNP node's initial operating system.

`bastion_ssh_user` defaults to `rocky`. If using a different image, set it to that
image's existing default username and use the same value in Ansible. Cloud-init
keeps that user's password locked while inheriting the provider's remaining user
settings and SSH key configuration. This avoids the Latitude Rocky image's attempt
to unlock an empty password. The override passed schema and user-normalization
checks with cloud-init 24.4; a fresh provision with the override remains to be tested.
`MIRROR_READY` records registry bootstrap success; check `cloud-init status --long`
separately for errors in other modules.

Cloud-init explicitly installs `hostname`, `openssh-clients` and `openssh-server` alongside
the registry dependencies. Before generating credentials or downloading the archive,
bootstrap checks the required commands and that `hostname -f` succeeds. Fix the bastion's
hostname in DNS or `/etc/hosts` if that check fails: mirror-registry evaluates it even when
`--targetHostname localhost` is supplied.

The public **2.0.12 AMD64 archive** was downloaded and matched Red Hat's published checksum
on 2026-10-05. Its root-level executable and bundled images match this bootstrap's extraction
layout; install flags were checked with `--help`. The October 5 run installed it, verified TLS/DNS, completed mirroring and passed an unchanged preparation rerun. Guest pulls remain a later checkpoint. Use these explicit inputs:

```hcl
mirror_registry_url    = "https://mirror.openshift.com/pub/cgw/mirror-registry/2.0.12/mirror-registry-amd64.tar.gz"
mirror_registry_sha256 = "6de43edfd77a61bb27116bb7a9a5715884722a811f92cd5d9dfca406afb457b2"
```

Source: [Red Hat's versioned archive and checksum listing](https://mirror.openshift.com/pub/cgw/mirror-registry/2.0.12/).
Recheck the current release and checksum when preparing a later validation run.

## Provision

Follow the [current quickstart](../../../docs/current-quickstart.md) and
[Latitude validation procedure](../../../docs/latitude-validation.md) for controller
prerequisites, external Terraform state and variable files, plan review and provisioning.
Keep the bastion and node states separate. Set the versioned registry inputs above in the
external bastion variable file; do not place credentials or Terraform state in this checkout.

`firewall_name` defaults to `coco-node-inbound-hardening`, preserving existing rigs.
For parallel rigs in the same Latitude project, set a distinct name in each external
variable file (for example, `coco-mia2-node-inbound`). The pinned provider locates a
new firewall by project and name, so duplicate names can select the wrong resource.

Inspect bootstrap through SSH with sufficient privileges: `sudo tail -f /var/log/mirror-bootstrap.log`. The root-owned `<mirror_root>/MIRROR_READY` marker records bootstrap completion; `MIRROR_FAILED` records failure. Check the protected log before retrying. The preparation play also verifies DNS and the serving registry path.

The generated registry password lives at `/opt/mirror/mirror-admin-password` with mode 0600. The public CA is `/opt/mirror/ca/rootCA.pem`. Ansible reads these files and builds the required authentication and trust configuration; do not copy the password into terminal output, Terraform inputs, user-data or the checkout.

## Firewall assignment and network enforcement

Latitude's [current firewall documentation](https://www.latitude.sh/docs/networking/firewall)
describes a host-installed UFW/iptables agent and inbound/outbound rules. API assignment and
agent installation are separate steps. This repository creates the firewall object and optional
assignment; it does not install or verify that agent. Keep `enforce_latitude_firewall=false`
for the maintained RHCOS path. Agent compatibility and persistence through reinstall are unvalidated.

The [pinned provider's firewall documentation](https://github.com/latitudesh/terraform-provider-latitudesh/blob/v4.6.0/docs/resources/firewall.md)
also records an automatic SSH rule that remains outside Terraform state and survives rule
updates. Consequently, the configured `admin_cidr` does not establish exclusive SSH access.
Inspect effective API and host rules and test allowed/denied traffic before claiming restriction.

The bastion's `bastion_egress` role tunes MTU/MSS; it retains outbound access for mirroring.
The separate [RHCOS egress MachineConfig](../../../gitops/base/airgap-egress/) is applied manually
after cluster health is established and filters host `OUTPUT`. A failed host `curl` alone does
not establish Trustee pod or guest isolation. Follow the [network acceptance checks](../../../docs/latitude-validation.md#acceptance-evidence),
including private-service controls and fresh probes after reboot. The raw provider OS's firewall
does not establish the installed RHCOS policy; RHCOS configuration follows the
[Ignition/Machine Config Operator lifecycle](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/architecture/architecture-rhcos).

## Tear down (only at the end of the engagement)

Use the teardown steps in the [Latitude validation procedure](../../../docs/latitude-validation.md)
with the same external state and variable files used to provision. Destroy the node first,
then the bastion when the mirror cache is no longer needed.

Retain the configuration revision and rendered bootstrap identity for each deployment in
private external state. Provider 4.6.0 can report `Server Reinstall Required` even during
destroy planning when the current user-data differs from the deployed payload. In that case,
plan with the recorded deployed configuration and the same state, verify that the plan contains
only the intended deletions, and apply that saved plan with the explicit state path. Keep
`allow_reinstall=false`; cleanup does not require an OS reinstall.

An interrupted create can leave a billable server at Latitude before Terraform records its
ID. Inspect the provider inventory and the same external state before retrying. Once the old
Terraform process has exited, back up the state and import the verified existing server ID if
its resource is absent. Review a new plan; the previous create plan is no longer safe to apply.
