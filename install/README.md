# Installer inputs

Use [the quickstart](../docs/current-quickstart.md) for installation. This directory
contains the selected release inventory and templates, not an independent manual procedure.

| File | Purpose |
|---|---|
| `release-manifest.json` | Exact platform, Operator, image and tool identities |
| `imageset-config.yaml` | Matching oc-mirror v2 content selection |
| [Ansible templates](../ansible/roles/render_configs/templates/) | Cluster, disk, MAC and private-network inputs |

Ansible renders actual verified values. Keep generated configuration/assets in
private external storage; never create credential-bearing `cluster-assets` here.

Check the disk serial and stable `/dev/disk/by-path/` hint, permanent MACs, VLAN wire
tag, addresses/subnet, rendezvous IP, DNS/NTP, mirror CA/authentication and cluster
name/domain. Match installer and payload identities to the manifest.

Use `make preflight` for local inventory agreement. It does not contact registries
or prove hardware support. [Release resolution](../docs/release-resolution.md)
explains refresh; [firmware preflight](../docs/amd-firmware-preflight.md) qualifies the node.

Operator/runtime/Trustee installation follows platform health. For a disposable
software reset, use [maintenance](../docs/maintenance.md#reset-a-disposable-coco-lab);
resetting CoCo does not reinstall OpenShift.
