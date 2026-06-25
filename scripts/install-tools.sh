#!/usr/bin/env bash
# Fetch version-pinned OpenShift client tooling into ./bin for the disconnected SNO prep.
#
# Pulls oc, openshift-install (4.20.18) and oc-mirror from the public Red Hat mirror
# (https://mirror.openshift.com/pub/openshift-v4/clients/...). linux/amd64 only. Idempotent:
# re-running re-extracts the pinned versions and prints what landed.
#
# NOTE (disconnected): for the real air-gapped install the installer should ultimately come
# from `oc adm release extract --command=openshift-install` run against the MIRRORED release
# image, so it matches the payload byte-for-byte. THIS script only fetches the public
# binaries to bootstrap the mirroring/prep step. See install/README.md step 3.
set -euo pipefail

OCP_VERSION="${OCP_VERSION:-4.20.18}"        # VERIFY: matches install/imageset-config.yaml pin
ARCH="amd64"
OS="linux"
BIN_DIR="${BIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin}"
MIRROR="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients"

mkdir -p "${BIN_DIR}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fetch() {  # fetch <url> <outfile>
  echo ">> downloading $1"
  curl -fsSL "$1" -o "$2"
}

# --- oc + kubectl (openshift-client) and openshift-install, pinned to OCP_VERSION ---------
fetch "${MIRROR}/ocp/${OCP_VERSION}/openshift-client-${OS}-${OCP_VERSION}.tar.gz" "${TMP}/oc.tgz"
tar -xzf "${TMP}/oc.tgz" -C "${BIN_DIR}" oc kubectl

fetch "${MIRROR}/ocp/${OCP_VERSION}/openshift-install-${OS}-${OCP_VERSION}.tar.gz" "${TMP}/install.tgz"
tar -xzf "${TMP}/install.tgz" -C "${BIN_DIR}" openshift-install

# --- oc-mirror (v2). Lives under .../clients/ocp-tools, versioned by the same train. -------
# VERIFY the exact path/filename for your release; the ocp-tools dir uses a 'latest' symlink
# plus per-version dirs. We pin to OCP_VERSION first, fall back to latest with a warning.
OCMIRROR_URL="${MIRROR}/ocp-tools/${OCP_VERSION}/oc-mirror.tar.gz"
if ! curl -fsI "${OCMIRROR_URL}" >/dev/null 2>&1; then
  echo ">> WARN: ${OCMIRROR_URL} not found; falling back to ocp-tools/latest (VERIFY version)"
  OCMIRROR_URL="${MIRROR}/ocp-tools/latest/oc-mirror.tar.gz"
fi
fetch "${OCMIRROR_URL}" "${TMP}/oc-mirror.tgz"
tar -xzf "${TMP}/oc-mirror.tgz" -C "${BIN_DIR}" oc-mirror

chmod +x "${BIN_DIR}"/oc "${BIN_DIR}"/kubectl "${BIN_DIR}"/openshift-install "${BIN_DIR}"/oc-mirror

# --- report versions ---------------------------------------------------------------------
echo
echo "Installed into ${BIN_DIR}:"
"${BIN_DIR}/oc" version --client
"${BIN_DIR}/openshift-install" version
"${BIN_DIR}/oc-mirror" version 2>/dev/null || "${BIN_DIR}/oc-mirror" --v2 version 2>/dev/null || true
echo
echo "Add to PATH:  export PATH=\"${BIN_DIR}:\$PATH\""
