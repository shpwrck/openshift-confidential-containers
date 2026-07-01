#!/usr/bin/env bash
# Run ON THE BASTION (as rocky, uses sudo). Installs pinned tools to /usr/local/bin, trusts the
# mirror CA, and builds the merged /root/.docker/config.json (RH pull-secret + mirror creds).
# Does NOT run the oc-mirror push — that is a separate backgrounded step (bastion-mirror-push.sh).
set -euo pipefail
OCP_VERSION="${OCP_VERSION:-4.20.18}"
MIRROR="https://mirror.openshift.com/pub/openshift-v4/amd64/clients"
MIRROR_ENDPOINT="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
MIRROR_USER="init"
PULL_SECRET_SRC="${HOME}/pull-secret.json"
MIRROR_PW="$(sudo cat /opt/mirror/mirror-admin-password)"

echo "=== 1. tools -> /usr/local/bin (idempotent) ==="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
need() { ! command -v "$1" >/dev/null 2>&1; }
if need oc || need openshift-install; then
  curl -fsSL "${MIRROR}/ocp/${OCP_VERSION}/openshift-client-linux-${OCP_VERSION}.tar.gz" -o "$TMP/oc.tgz"
  sudo tar -xzf "$TMP/oc.tgz" -C /usr/local/bin oc kubectl
  curl -fsSL "${MIRROR}/ocp/${OCP_VERSION}/openshift-install-linux-${OCP_VERSION}.tar.gz" -o "$TMP/install.tgz"
  sudo tar -xzf "$TMP/install.tgz" -C /usr/local/bin openshift-install
fi
if need oc-mirror; then
  # RHEL-family bastion: prefer the rhel9 build (no libgpgme dep). Fall back to glibc build.
  OCM_URL="${MIRROR}/ocp/${OCP_VERSION}/oc-mirror.rhel9.tar.gz"
  curl -fsI "$OCM_URL" >/dev/null 2>&1 || OCM_URL="${MIRROR}/ocp/${OCP_VERSION}/oc-mirror.tar.gz"
  echo ">> oc-mirror from $OCM_URL"
  curl -fsSL "$OCM_URL" -o "$TMP/ocm.tgz"
  sudo tar -xzf "$TMP/ocm.tgz" -C /usr/local/bin oc-mirror
fi
sudo chmod +x /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/openshift-install /usr/local/bin/oc-mirror
echo "oc: $(oc version --client 2>/dev/null | head -1)"
echo "openshift-install: $(openshift-install version 2>/dev/null | head -1)"
echo "oc-mirror: $(oc-mirror version 2>/dev/null || oc-mirror --v2 version 2>/dev/null || echo '?')"

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
