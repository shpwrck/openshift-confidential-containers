# Disconnected SNO install — Agent-based Installer (SEV-SNP bare metal)

Brings up a **single-node OpenShift** cluster, fully air-gapped, as the CoCo verification rig.
Target: **OCP 4.20.18** (alt 4.19.28), **OSC 1.12**, **Trustee 1.1**, TEE = **AMD SEV-SNP**.
The node is egress-firewalled to reach only the bastion mirror registry.

This directory only covers the **install**. Operator install order (NFD → cert-manager → OSC
→ Trustee) and attestation live under `gitops/` and `docs/` — not here.

## Prerequisites

- A SEV-SNP-capable bare-metal node with BIOS already proven (see
  `docs/notes/latitude-snp-bringup.md` for the AMI Aptio sequence). SNO needs **≥ the
  documented minimums** — currently **8 vCPU / 16 GiB RAM / 120 GiB disk** (VERIFY against
  the OCP 4.20 SNO docs; CoCo CVMs add headroom, size up).
- A **bastion host** running a mirror registry (e.g. quay/Harbor) reachable from the node,
  with its CA cert and a pull credential.
- Tools on the bastion/admin host: `oc`, `openshift-install`, `oc-mirror` — fetch with
  `scripts/install-tools.sh` (all pinned to 4.20.18 / linux-amd64).
- The node's facts: root device, NIC MAC, static IP/gateway/DNS, machineNetwork subdomain.
  Several are TBD until the node is in hand (see TODOs at the bottom).

## Order of operations

1. **Mirror the content** to the bastion (oc-mirror **v2**):
   ```bash
   ./scripts/install-tools.sh                      # gets oc / openshift-install / oc-mirror into ./bin
   export MIRROR_REGISTRY=bastion.example.com:8443 # your mirror host:port
   ./scripts/mirror.sh mirror                       # runs oc-mirror --v2 -c install/imageset-config.yaml
   ```
   Verify the operator **channels** in `install/imageset-config.yaml` first (they carry
   `# VERIFY`). oc-mirror v2 also emits cluster resources (IDMS/ITMS + CatalogSource) under
   the workspace — keep them for **post-install** (`./scripts/mirror.sh resources`).

2. **Fill the templates.** Copy both into a fresh assets dir and replace every `# FILL:`:
   ```bash
   mkdir -p cluster-assets
   cp install/install-config.yaml.tmpl cluster-assets/install-config.yaml
   cp install/agent-config.yaml.tmpl  cluster-assets/agent-config.yaml
   # edit both: see "Filling placeholders" below
   ```

3. **Build the agent ISO** (consumes the two YAMLs from the assets dir):
   ```bash
   ./bin/openshift-install --dir cluster-assets agent create image
   # -> cluster-assets/agent.x86_64.iso
   ```
   For disconnected, the `openshift-install` binary should ultimately come from
   `oc adm release extract --command=openshift-install` against the **mirrored** release so
   it matches the air-gapped payload; `install-tools.sh` fetches the public one for prep.

4. **Boot the node** from that ISO, one of:
   - **Latitude IPMI virtual media** — attach `agent.x86_64.iso` via the browser IPMI/KVM
     (`POST /servers/{id}/remote_access`, see `infra/latitude/README.md`), set one-time boot
     to virtual CD, reboot.
   - **Custom iPXE** — serve the ISO/kernel+initrd from the bastion and chain-load it.

5. **Wait for completion** (run from the admin host with network line-of-sight to the node):
   ```bash
   ./bin/openshift-install --dir cluster-assets agent wait-for bootstrap-complete
   ./bin/openshift-install --dir cluster-assets agent wait-for install-complete
   # kubeconfig + kubeadmin password land in cluster-assets/auth/
   ```

## Filling placeholders

| Placeholder | Where | How to get it |
|---|---|---|
| `baseDomain`, `metadata.name` | install-config | Your DNS plan; cluster FQDN = name.baseDomain |
| `machineNetwork` cidr | install-config | The node's L2 subnet (must contain the node IP + rendezvousIP) |
| `imageDigestSources` mirrors | install-config | `MIRROR_REGISTRY` + the two repo paths oc-mirror wrote |
| `additionalTrustBundle` | install-config | PEM of the mirror registry's CA chain |
| `pullSecret` | install-config | **Mirror** creds only (base64 user:pass), not the RH cloud secret |
| `sshKey` | install-config | Your `~/.ssh/<key>.pub` |
| `rendezvousIP` | agent-config | The single node's static IPv4 (SNO: = the host IP) |
| `hostname`, `role` | agent-config | Node hostname; role stays `master` |
| `rootDeviceHints.deviceName` | agent-config | `lsblk` on the node — `/dev/nvme0n1` or `/dev/sda` |
| `interfaces[].macAddress` | agent-config | Real NIC MAC from IPMI / `ip link` — never guess |
| `networkConfig` (ip/dns/routes) | agent-config | Static IPv4, gateway, and a DNS that resolves both cluster + mirror |

## TODOs (resolve on the node, tomorrow)

- Confirm **root device** (`/dev/nvme0n1` vs `/dev/sda`) and lock `rootDeviceHints`.
- Capture the **NIC name + MAC** from IPMI/`ip link`.
- Confirm the **static IP / gateway / DNS / subnet** assigned to the node.
- VERIFY all four operator **channels** in `imageset-config.yaml`.
- VERIFY the OCP 4.20 SNO **minimum RAM/disk** numbers above.
