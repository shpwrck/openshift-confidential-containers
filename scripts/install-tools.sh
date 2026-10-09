#!/usr/bin/env bash
# Install a checksum-verified OpenShift tool set; safe to rerun after a release change.
# Also staged standalone by Ansible, which supplies OCP_VERSION explicitly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/lib/release.sh" ]]; then
  # shellcheck source=scripts/lib/release.sh
  source "$SCRIPT_DIR/lib/release.sh"
  load_release_defaults
fi
: "${OCP_VERSION:?set OCP_VERSION or use the repository release manifest}"
[[ "$OCP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: OCP_VERSION must be an exact release" >&2; exit 2; }
BIN_DIR="${BIN_DIR:-$SCRIPT_DIR/../bin}"
OCP_CLIENTS_BASE="${OCP_CLIENTS_BASE:-https://mirror.openshift.com/pub/openshift-v4/amd64/clients}"
OCMIRROR_VARIANT="${OCMIRROR_VARIANT:-rhel9}"
case "$OCMIRROR_VARIANT" in rhel9|glibc) ;; *) echo "ERROR: OCMIRROR_VARIANT must be rhel9 or glibc" >&2; exit 2 ;; esac
base="${OCP_CLIENTS_BASE%/}/ocp/$OCP_VERSION"
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN_DIR" "$TMP/stage"
BIN_DIR="$(cd "$BIN_DIR" && pwd)"
if ! mkdir "$BIN_DIR/.coco-tools-lock" 2>/dev/null; then
  echo "ERROR: another tool install owns $BIN_DIR/.coco-tools-lock; inspect it before removing a stale lock" >&2
  exit 1
fi
trap 'rm -rf "$TMP"; rmdir "$BIN_DIR/.coco-tools-lock"' EXIT
die() { echo "ERROR: $*" >&2; exit 1; }
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "install sha256sum or shasum before fetching tools"; fi
}
fetch() { curl --fail --silent --show-error --location --retry 3 "$1" -o "$2"; }
fetch "$base/sha256sum.txt" "$TMP/sha256sum.txt" || die "checksums unavailable for $OCP_VERSION at $base; no latest fallback"
checksum() {
  local name="$1" result
  result="$(awk -v name="$name" '{file=$2; sub(/^\*/, "", file); if(file==name) print $1}' "$TMP/sha256sum.txt")"
  [[ "$result" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$result" | tr '[:upper:]' '[:lower:]'
}
client="openshift-client-linux-$OCP_VERSION.tar.gz"
installer="openshift-install-linux-$OCP_VERSION.tar.gz"
mirror="oc-mirror.tar.gz"
# A variant fallback stays in this exact release and requires its published checksum.
if [[ "$OCMIRROR_VARIANT" == rhel9 ]] && checksum oc-mirror.rhel9.tar.gz >/dev/null; then mirror="oc-mirror.rhel9.tar.gz"; fi
for archive in "$client" "$installer" "$mirror"; do
  digest="$(checksum "$archive")" || die "no unique published checksum for $archive in $OCP_VERSION"
  printf '%s %s\n' "$archive" "$digest" >> "$TMP/archives"
done
fingerprint="$(sha "$TMP/archives")"
marker="$BIN_DIR/.coco-tools-manifest"
reusable=1
[[ -f "$marker" ]] && [[ "$(head -n 1 "$marker")" == "$OCP_VERSION $fingerprint" ]] || reusable=0
for binary in oc kubectl openshift-install oc-mirror; do
  if [[ ! -x "$BIN_DIR/$binary" ]] || [[ ! -f "$marker" ]]; then reusable=0; continue; fi
  expected="$(awk -v name="$binary" '$1==name {print $2}' "$marker")"
  [[ "$expected" == "$(sha "$BIN_DIR/$binary")" ]] || reusable=0
done
if [[ "$reusable" == 1 ]]; then
  echo "OpenShift $OCP_VERSION tools verified in $BIN_DIR"
  echo "COCO_TOOLS_CHANGED=0"
  exit 0
fi
for archive in "$client" "$installer" "$mirror"; do
  fetch "$base/$archive" "$TMP/$archive" || die "requested archive unavailable: $base/$archive"
  [[ "$(sha "$TMP/$archive")" == "$(checksum "$archive")" ]] || die "checksum mismatch: $archive; installed tools were not replaced"
done
tar -xzf "$TMP/$client" -C "$TMP/stage" oc kubectl
tar -xzf "$TMP/$installer" -C "$TMP/stage" openshift-install
tar -xzf "$TMP/$mirror" -C "$TMP/stage" oc-mirror
chmod 755 "$TMP/stage/oc" "$TMP/stage/kubectl" "$TMP/stage/openshift-install" "$TMP/stage/oc-mirror"
# Detect an incorrect platform/archive before replacing a working installation.
"$TMP/stage/oc" version --client >/dev/null
install_version="$("$TMP/stage/openshift-install" version)"
[[ "$(printf '%s\n' "$install_version" | awk 'NR==1 {print $2}')" == "$OCP_VERSION" ]] || die "installer does not report requested release $OCP_VERSION"
"$TMP/stage/oc-mirror" version >/dev/null 2>&1 || "$TMP/stage/oc-mirror" --v2 version >/dev/null
printf '%s %s\n' "$OCP_VERSION" "$fingerprint" > "$TMP/manifest"
for binary in oc kubectl openshift-install oc-mirror; do
  printf '%s %s\n' "$binary" "$(sha "$TMP/stage/$binary")" >> "$TMP/manifest"
  # Publish each complete binary atomically. An interrupted set has no valid completion record.
  cp "$TMP/stage/$binary" "$BIN_DIR/.$binary.coco-new"
  chmod 755 "$BIN_DIR/.$binary.coco-new"
  mv -f "$BIN_DIR/.$binary.coco-new" "$BIN_DIR/$binary"
done
cp "$TMP/manifest" "$marker.new"
mv -f "$marker.new" "$marker"
echo "Installed and verified OpenShift $OCP_VERSION tools in $BIN_DIR"
echo "COCO_TOOLS_CHANGED=1"
