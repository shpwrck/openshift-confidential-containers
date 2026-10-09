# Mirror helper module

This module owns the helper, private VLAN and firewall API object. Separate state
lets the node be replaced while the mirror cache remains. Both servers incur charges
until deleted; [provisioning and cleanup](../README.md) use external state.

## Registry prerequisites

The lab default is Rocky Linux 9; this does not inherit Red Hat host support.
[Red Hat's mirror-registry prerequisites](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/installing-mirroring-creating-registry)
specify RHEL 8/9, Podman, OpenSSL, DNS and SSH.
Use the selected image's actual SSH user consistently in Terraform and Ansible.

Supply the versioned registry archive and published checksum in external tfvars.
The October 5/8 tests used:

```hcl
mirror_registry_url    = "https://mirror.openshift.com/pub/cgw/mirror-registry/2.0.12/mirror-registry-amd64.tar.gz"
mirror_registry_sha256 = "6de43edfd77a61bb27116bb7a9a5715884722a811f92cd5d9dfca406afb457b2"
```

[The versioned download listing](https://mirror.openshift.com/pub/cgw/mirror-registry/2.0.12/)
is the checksum source. Recheck identities when selecting a new version.

## Bootstrap and checks

Inspect `cloud-init status --long` and protected `/var/log/mirror-bootstrap.log`.
`<mirror_root>/MIRROR_READY` means registry bootstrap completed; it does not prove
all cloud-init modules succeeded or the node can reach the registry.
`MIRROR_FAILED` requires log diagnosis before a retry.

The default password file is `/opt/mirror/mirror-admin-password` (`0600`); the public
CA is `/opt/mirror/ca/rootCA.pem`. Ansible reads credentials without printing them.
The hostname must resolve and `hostname -f` must work for mirror installation.

Use a distinct `firewall_name` for each parallel rig: the pinned provider locates
objects by project/name. API firewall assignment is separate from agent enforcement;
the module does not install or verify that agent. Its automatic SSH rule is also
outside Terraform state, so `admin_cidr` alone does not prove exclusive access.

Bastion MTU/MSS tuning retains egress for staging. Host `OUTPUT` filtering alone
does not prove pod or guest isolation. Verify private controls and public denials at
all three layers after installation/reboot, as required by [validation](../../../docs/validation/README.md).
Keep private-to-public forwarding blocked when preparing a disconnected private rig.
