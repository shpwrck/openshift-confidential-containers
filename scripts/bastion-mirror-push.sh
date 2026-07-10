#!/usr/bin/env bash
# Run ON THE BASTION after bastion-mirror-setup.sh. Pushes the imageset to the local mirror
# registry (oc-mirror v2). ~10 min for the 4.20.18 SNO + 4 operators payload. Backgroundable.
# Markers: /opt/mirror/OCMIRROR_DONE | /opt/mirror/OCMIRROR_FAILED ; log /opt/mirror/oc-mirror-push.log
#
# NOTE (#55): these raw bastion-*.sh scripts are the low-level "manual equivalent" pieces. The
# reproducible, fully-wired path is `make bringup-sno-airgapped` (Ansible), which runs the
# bastion_egress hardening (fix #1) FIRST. This script assumes that ran and PREFLIGHTS for it below.
set -uo pipefail
unset REGISTRY_AUTH_FILE   # v2 embeds a distribution registry that hijacks REGISTRY_* -> panic
MIRROR_ENDPOINT="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
WORKSPACE="/opt/mirror/ocm-workspace"
CONFIG="${HOME}/imageset-config.yaml"
LOG="/opt/mirror/oc-mirror-push.log"
EGRESS_NFT_TABLE="${EGRESS_NFT_TABLE:-egress_clamp}"

# --- Egress preflight (#55) --------------------------------------------------
# Without the bastion_egress hardening (drop v6 default route + MTU/MSS clamp), oc-mirror's large
# quay-CDN blobs blackhole mid-stream ("unexpected EOF"). Fail LOUD rather than waste a multi-GB pull.
egress_hardened() {
	! ip -6 route show default 2>/dev/null | grep -q . &&
		sudo nft list table inet "$EGRESS_NFT_TABLE" 2>/dev/null | grep -q 'maxseg size set'
}
if [ "${SKIP_EGRESS_CHECK:-0}" != 1 ] && ! egress_hardened; then
	cat >&2 <<EOF
FATAL: bastion egress is NOT hardened — this push will likely blackhole large quay-CDN blobs
       ("unexpected EOF"): a live IPv6 default route and/or a missing SYN MSS clamp were found.
Fix (any one), then re-run:
  - Preferred:   make bringup-sno-airgapped                         # runs the bastion_egress role
  - Egress only: ansible-playbook ansible/playbooks/site.yml --tags egress
  - Manual on this bastion:
      sudo ip -6 route del default
      sudo ip route change \$(ip -4 route show default | sed -E 's/[[:space:]]+mtu[[:space:]]+[0-9]+//') mtu 1400
      sudo nft -f /etc/nftables/${EGRESS_NFT_TABLE}.nft
  - Override (NOT recommended): SKIP_EGRESS_CHECK=1 $0
EOF
	exit 3
fi

sudo rm -f /opt/mirror/OCMIRROR_DONE /opt/mirror/OCMIRROR_FAILED
sudo mkdir -p "$WORKSPACE"
echo "=== oc-mirror v2 push -> ${MIRROR_ENDPOINT} (workspace ${WORKSPACE}) ==="
# Run as root so it reads /root/.docker/config.json and can write the root-owned workspace.
# shellcheck disable=SC2024  # sudo applies to `tee` inside the process substitution, not a redirect
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
