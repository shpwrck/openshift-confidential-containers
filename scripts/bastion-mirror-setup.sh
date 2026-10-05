#!/usr/bin/env bash
# Run ON THE BASTION (as rocky, uses sudo). Installs pinned tools to /usr/local/bin, trusts the
# mirror CA, and builds the merged /root/.docker/config.json (RH pull-secret + mirror creds).
# Does NOT run the oc-mirror push — use the maintained Ansible mirror phase after setup.
#
# NOTE (#55): low-level "manual equivalent" script. Prefer `make bringup-sno-airgapped` (Ansible),
# which wires these steps in order incl. the bastion_egress hardening (fix #1) the push depends on.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"
load_release_defaults
MIRROR_ENDPOINT="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
MIRROR_USER="init"
PULL_SECRET_SRC="${HOME}/pull-secret.json"
MIRROR_PW="$(sudo cat /opt/mirror/mirror-admin-password)"

echo "=== 1. tools -> /usr/local/bin (idempotent) ==="
sudo env OCP_VERSION="$OCP_VERSION" OCP_CLIENTS_BASE="$OCP_CLIENTS_BASE" \
  BIN_DIR=/usr/local/bin OCMIRROR_VARIANT=rhel9 bash "$SCRIPT_DIR/install-tools.sh"

echo "=== 2. trust the mirror CA ==="
sudo cp /opt/mirror/ca/rootCA.pem /etc/pki/ca-trust/source/anchors/coco-mirror-rootCA.pem
sudo update-ca-trust
curl -s "https://${MIRROR_ENDPOINT}/health/instance" | head -c 120; echo " <- mirror health (CA-trusted)"

echo "=== 3. merged /root/.docker/config.json (RH pull-secret + mirror creds) ==="
test -f "$PULL_SECRET_SRC" || { echo "FATAL: $PULL_SECRET_SRC missing (scp it first)"; exit 2; }
# Runs on the bastion (Rocky Linux / GNU coreutils; see header) — `base64 -w0` kept intentionally.
MIRROR_AUTH_B64="$(printf '%s:%s' "$MIRROR_USER" "$MIRROR_PW" | base64 -w0)"
sudo mkdir -p /root/.docker
sudo python3 - "$PULL_SECRET_SRC" "$MIRROR_ENDPOINT" "$MIRROR_AUTH_B64" <<'PY'
import json,sys
src,endpoint,auth=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(src))
d.setdefault("auths",{})[endpoint]={"auth":auth,"email":"noreply@coco.rig.local"}
json.dump(d,open("/root/.docker/config.json","w"),indent=2)
print("merged auths:",list(d["auths"].keys()))
PY
sudo chmod 600 /root/.docker/config.json
echo "=== setup OK ==="
