#!/usr/bin/env bash
# Run ON THE BASTION after bastion-mirror-setup.sh. Pushes the imageset to the local mirror
# registry (oc-mirror v2). ~10 min for the 4.20.18 SNO + 4 operators payload. Backgroundable.
# Markers: /opt/mirror/OCMIRROR_DONE | /opt/mirror/OCMIRROR_FAILED ; log /opt/mirror/oc-mirror-push.log
set -uo pipefail
unset REGISTRY_AUTH_FILE   # v2 embeds a distribution registry that hijacks REGISTRY_* -> panic
MIRROR_ENDPOINT="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
WORKSPACE="/opt/mirror/ocm-workspace"
CONFIG="${HOME}/imageset-config.yaml"
LOG="/opt/mirror/oc-mirror-push.log"

sudo rm -f /opt/mirror/OCMIRROR_DONE /opt/mirror/OCMIRROR_FAILED
sudo mkdir -p "$WORKSPACE"
echo "=== oc-mirror v2 push -> ${MIRROR_ENDPOINT} (workspace ${WORKSPACE}) ==="
# Run as root so it reads /root/.docker/config.json and can write the root-owned workspace.
sudo env PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  oc-mirror --v2 -c "$CONFIG" --workspace "file://${WORKSPACE}" "docker://${MIRROR_ENDPOINT}" \
  > >(sudo tee "$LOG") 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  sudo touch /opt/mirror/OCMIRROR_DONE
  echo "=== OCMIRROR_DONE ==="
  echo "--- cluster-resources emitted ---"
  sudo ls -la "${WORKSPACE}/working-dir/cluster-resources/" 2>&1
else
  sudo touch /opt/mirror/OCMIRROR_FAILED
  echo "=== OCMIRROR_FAILED (rc=$RC) — see $LOG ==="
  exit $RC
fi
