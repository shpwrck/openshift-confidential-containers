#!/usr/bin/env bash
# Air-gap VCEK collection for the Trustee OfflineStore (the customer sign-off gate).
# Generation-agnostic (dodges trustee bug #591 'Milan' hardcode). Re-runnable so it also
# serves the TCB-refresh case after a firmware update.
#
# DESIGN (see docs/design/engagement-design.md §4):
#   per socket:  snphost show vcek-url  -> hwid + KDS URL
#   connected:   download <url> -> vcek.der            (run where KDS is reachable)
#   air-gapped:  one K8s secret per LOWERCASE hwid, mounted via KbsConfig.kbsLocalCertCacheSpec
#                at /opt/confidential-containers/attestation-service/kds-store/vcek/<hwid>/vcek.der
#
# This script does the real work; it is hardware-bound, so it MUST run against a live node
# with `oc` logged in. Two-step flow when the admin host can't reach AMD KDS:
#   1) run it once on a host with `oc` access  -> writes <OUT>/<hwid>/vcek.url per socket;
#   2) on a KDS-CONNECTED host, run `--download` (curls each .url -> vcek.der);
#   3) run it again with `oc` access (.der now present) -> creates one secret per hwid.
# When the host running step 1 IS internet-connected, all three happen in one pass.
#
# Usage:
#   ./scripts/collect-vcek.sh <node-name> [namespace]   # collect urls (+ download if KDS reachable) + create secrets
#   ./scripts/collect-vcek.sh --download                # offline KDS download step only (no oc needed)
# Env: OUT=./vcek-bundle  TOOLS_IMG=...  KDS_HOST=kdsintf.amd.com
set -euo pipefail

OUT="${OUT:-./vcek-bundle}"
TOOLS_IMG="${TOOLS_IMG:-quay.io/openshift_sandboxed_containers/coco-tools@sha256:89c219d2c7cb8359e8cc86605df1d31ce3be0f2565683b8bff882dba0c8e2605}"
PODMAN_AUTHFILE="${PODMAN_AUTHFILE:-/var/lib/kubelet/config.json}"
KDS_HOST="${KDS_HOST:-kdsintf.amd.com}"
PATH="/usr/local/bin:${PATH}"
export PATH

if [[ -z "${KUBECONFIG:-}" && -r /opt/install/cluster-assets/auth/kubeconfig ]]; then
  export KUBECONFIG="/opt/install/cluster-assets/auth/kubeconfig"
fi

die() { echo "ERROR: $*" >&2; exit 1; }

# --- download-only mode: curl every collected .url on a KDS-connected host ----------------
if [[ "${1:-}" == "--download" ]]; then
  shopt -s nullglob
  urls=("${OUT}"/*/vcek.url)
  [[ ${#urls[@]} -gt 0 ]] || die "no ${OUT}/*/vcek.url found — run the collect step (with oc) first"
  for u in "${urls[@]}"; do
    d="$(dirname "$u")"
    echo ">> downloading VCEK for $(basename "$d")"
    curl -fsSL "$(cat "$u")" -o "${d}/vcek.der"
  done
  echo "Downloaded ${#urls[@]} VCEK cert(s). Carry ${OUT}/ into the air gap and re-run with <node> to create secrets."
  exit 0
fi

NODE="${1:?usage: collect-vcek.sh <node-name> [namespace]   |   collect-vcek.sh --download}"
NS="${2:-trustee-operator-system}"
command -v oc >/dev/null || die "oc not on PATH"
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
mkdir -p "${OUT}"

# Run a command in a privileged coco-tools container on the node, via `oc debug node`.
on_node() {  # on_node <shell-command-string>
  local podman_args=(run --rm --authfile "${PODMAN_AUTHFILE}" --privileged -v /dev:/dev)
  oc debug "node/${NODE}" -- chroot /host \
    podman "${podman_args[@]}" "${TOOLS_IMG}" bash -c "$1"
}

# Socket count — one VCEK per physical socket. VERIFY the field on the metal (`lscpu`).
SOCKETS="$(oc debug "node/${NODE}" -- chroot /host lscpu 2>/dev/null \
            | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')"
[[ "${SOCKETS}" =~ ^[0-9]+$ ]] || die "could not read socket count from the node"
echo ">> ${NODE}: ${SOCKETS} socket(s)"

created=0
for ((s=0; s<SOCKETS; s++)); do
  # snphost 1.12 has no --socket flag; only use it when a multi-socket host requires it.
  vcek_cmd="/tools/snphost show vcek-url"
  if [[ "${SOCKETS}" -gt 1 ]]; then
    vcek_cmd="${vcek_cmd} --socket ${s}"
  fi
  vcek_out="$(on_node "${vcek_cmd}" 2>&1)" || die "snphost show vcek-url failed on socket ${s}: ${vcek_out}"
  url="$(grep -oE 'https://[^[:space:]]+' <<<"${vcek_out}" | head -1)"
  [[ -n "${url}" ]] || die "no VCEK URL returned for socket ${s}"

  # hwid is the path segment after the product name; LOWERCASE it (upper-case silently
  # misses the OfflineStore and falls through to the unreachable KDS -> attestation fails).
  hwid="$(echo "${url}" | sed -E 's#.*/v1/[^/]+/([^?]+).*#\1#' | tr 'A-Z' 'a-z')"
  [[ -n "${hwid}" && "${hwid}" != "${url}" ]] || die "could not parse HWID from URL: ${url}"
  dir="${OUT}/${hwid}"; mkdir -p "${dir}"; echo "${url}" > "${dir}/vcek.url"
  echo ">> socket ${s}: hwid ${hwid}"

  # Fetch the .der here if KDS is reachable; otherwise defer to the --download step.
  if [[ ! -s "${dir}/vcek.der" ]]; then
    if curl -fsS -m 8 -o /dev/null "https://${KDS_HOST}/" 2>/dev/null; then
      curl -fsSL "${url}" -o "${dir}/vcek.der"
    else
      echo "   KDS unreachable here — run \`$0 --download\` on a connected host, then re-run this."
      continue
    fi
  fi

  # One secret per hwid; idempotent (apply, not create) so TCB-refresh re-runs cleanly.
  oc create secret generic "vcek-${hwid}" --from-file=vcek.der="${dir}/vcek.der" \
     -n "${NS}" --dry-run=client -o yaml | oc apply -f -
  created=$((created+1))
done

echo
echo "Created/updated ${created}/${SOCKETS} VCEK secret(s) in ${NS}."
[[ ${created} -eq ${SOCKETS} ]] || die "some sockets lack a vcek.der — download them (--download) and re-run"
echo "Next: reference each secret in KbsConfig.spec.kbsLocalCertCacheSpec (mountPath"
echo "  .../kds-store/vcek/<hwid>/vcek.der). VERIFY the .der carries the ARK/ASK chain or supply"
echo "  ASK/ARK separately. Confirm hwid dirs are LOWERCASE."
