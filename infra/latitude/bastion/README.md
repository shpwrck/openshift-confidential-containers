# Latitude.sh bastion — persistent air-gap mirror host

The **long-lived** half of the rig. Stands up the disconnected-install support infrastructure
once, so the disposable SNP node (`../`) can be cycled underneath it freely:

- a **private virtual network** (VLAN) with real **L3** (static private IPs assigned in cloud-init),
- a **bastion** bare-metal host running Red Hat **`mirror-registry`** (quay) under a **DNS name
  mapped to its private IP**, so the node's pull validates the cert SAN (no `x509` IP-SAN failure),
- the **inbound-hardening firewall** the SNP node attaches to (egress lockdown is host nftables).

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

Inspect bootstrap through SSH with sufficient privileges: `sudo tail -f /var/log/mirror-bootstrap.log`. The root-owned `<mirror_root>/MIRROR_READY` marker records bootstrap completion; `MIRROR_FAILED` records failure. Check the protected log before retrying. The preparation play also verifies DNS and the serving registry path.

The generated registry password lives at `/opt/mirror/mirror-admin-password` with mode 0600. The public CA is `/opt/mirror/ca/rootCA.pem`. Ansible reads these files and builds the required authentication and trust configuration; do not copy the password into terminal output, Terraform inputs, user-data or the checkout.

## Two firewalls, two layers — don't confuse them

- **Inbound** to the node: `latitudesh_firewall` here (SSH/API/ingress from `admin_cidr` only,
  deny the rest). Attach via `-var enforce_latitude_firewall=true` in `../` (off by default so a
  wrong `admin_cidr` can't lock you out). `admin_cidr` is **required** — no `0.0.0.0/0` default.
- **Egress** lockdown (the air gap): **host-side nftables**, NOT a Latitude firewall — its egress
  direction is undocumented, so we don't ship a false control. Runbook Phase 1 has the
  default-deny-output-except-bastion snippet **and** the probe that proves public egress is
  actually blocked. Do not claim the air gap is enforced until that probe is green.

## Tear down (only at the end of the engagement)

Use the teardown steps in the [Latitude validation procedure](../../../docs/latitude-validation.md)
with the same external state and variable files used to provision. Destroy the node first,
then the bastion when the mirror cache is no longer needed.
