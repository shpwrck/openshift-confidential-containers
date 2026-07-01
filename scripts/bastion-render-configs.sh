#!/usr/bin/env bash
# Run ON THE BASTION. Renders install-config.yaml + agent-config.yaml for the disconnected SNO
# into /opt/install/src and stages a copy into /opt/install/cluster-assets (the agent installer
# CONSUMES the copies on `agent create`, so src/ stays the source of truth).
#
# Per-run inputs via env:
#   PARENT_MAC   = the node's VLAN-parent NIC MAC (Latitude internal/PXE role) — REQUIRED
#   TOKEN        = boot-artifacts URL token (matches node ipxe_url path)        — REQUIRED
#   VID          = VLAN id (terraform output virtual_network_vid)               — REQUIRED
#   BASTION_PUB  = bastion public IPv4                                          — REQUIRED
# Fixed rig facts:
CLUSTER=sno-coco; BASE=coco.lab.local
NODE_VLAN_IP=192.168.66.11; BASTION_VLAN_IP=192.168.66.10; VLAN_PREFIX=24
PARENT_IF=enp195s0f1                       # Genoa m4-metal-medium VLAN parent (internal/PXE NIC); VERIFY on metal
ROOT_DEV=/dev/nvme0n1
MIRROR_ENDPOINT="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
set -euo pipefail
: "${PARENT_MAC:?set PARENT_MAC}"; : "${TOKEN:?set TOKEN}"; : "${VID:?set VID}"; : "${BASTION_PUB:?set BASTION_PUB}"

SRC=/opt/install/src; ASSETS=/opt/install/cluster-assets
sudo mkdir -p "$SRC" "$ASSETS"

MIRROR_PW="$(sudo cat /opt/mirror/mirror-admin-password)"
# Runs on the bastion (Rocky Linux / GNU coreutils; see header) — `base64 -w0` kept intentionally.
MIRROR_AUTH_B64="$(printf 'init:%s' "$MIRROR_PW" | base64 -w0)"
CA_INDENTED="$(sudo sed 's/^/  /' /opt/mirror/ca/rootCA.pem)"
SSHKEY="$(cat ~/coco-rig.pub)"

echo "=== install-config.yaml ==="
sudo tee "$SRC/install-config.yaml" >/dev/null <<EOF
apiVersion: v1
baseDomain: ${BASE}
metadata:
  name: ${CLUSTER}
controlPlane:
  name: master
  replicas: 1
  architecture: amd64
compute:
  - name: worker
    replicas: 0
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: 192.168.66.0/24
platform:
  none: {}
imageDigestSources:
  - source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
    mirrors:
      - ${MIRROR_ENDPOINT}/openshift/release
  - source: quay.io/openshift-release-dev/ocp-release
    mirrors:
      - ${MIRROR_ENDPOINT}/openshift/release-images
additionalTrustBundle: |
${CA_INDENTED}
pullSecret: '{"auths":{"${MIRROR_ENDPOINT}":{"auth":"${MIRROR_AUTH_B64}","email":"noreply@coco.rig.local"}}}'
sshKey: |
  ${SSHKEY}
EOF

echo "=== agent-config.yaml ==="
sudo tee "$SRC/agent-config.yaml" >/dev/null <<EOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER}
rendezvousIP: ${NODE_VLAN_IP}
bootArtifactsBaseURL: http://${BASTION_PUB}:8080/${TOKEN}
additionalNTPSources:
  - ${BASTION_VLAN_IP}
hosts:
  - hostname: ${CLUSTER}-node
    role: master
    rootDeviceHints:
      deviceName: ${ROOT_DEV}
    interfaces:
      - name: ${PARENT_IF}
        macAddress: ${PARENT_MAC}
    networkConfig:
      interfaces:
        - name: ${PARENT_IF}
          type: ethernet
          state: up
          ipv4:
            enabled: false
          ipv6:
            enabled: false
        - name: ${PARENT_IF}.${VID}
          type: vlan
          state: up
          vlan:
            base-iface: ${PARENT_IF}
            id: ${VID}
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: ${NODE_VLAN_IP}
                prefix-length: ${VLAN_PREFIX}
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - ${BASTION_VLAN_IP}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${BASTION_VLAN_IP}
            next-hop-interface: ${PARENT_IF}.${VID}
EOF

echo "=== stage src -> cluster-assets ==="
sudo rm -f "$ASSETS/install-config.yaml" "$ASSETS/agent-config.yaml"
sudo cp "$SRC/install-config.yaml" "$SRC/agent-config.yaml" "$ASSETS/"
echo "Rendered. Sanity:"
sudo grep -E "name:|baseDomain|rendezvousIP|bootArtifactsBaseURL|macAddress|base-iface|id: ${VID}" "$ASSETS/agent-config.yaml" | head
echo "imageDigestSources mirrors:"; sudo grep -A1 mirrors "$ASSETS/install-config.yaml"
