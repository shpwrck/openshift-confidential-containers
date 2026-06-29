#!/usr/bin/env bash
# Air-gap VCEK collection for the Trustee OfflineStore (the customer sign-off gate).
# Generation-agnostic (dodges trustee bug #591 'Milan' hardcode). Re-runnable so it also
# serves the TCB-refresh case after a firmware update.
#
# DESIGN (see docs/design/engagement-design.md §4):
#   per chip:    snphost show vcek-url  -> hwid + KDS URL(s)
#   connected:   download <url> -> vcek.der            (run where KDS is reachable)
#   air-gapped:  one short K8s secret per VCEK, mounted via KbsConfig.kbsLocalCertCacheSpec
#                at /opt/confidential-containers/attestation-service/kds-store/vcek/<lowercase-hwid>/vcek.der
#
# This script does the real work; it is hardware-bound, so it MUST run against a live node
# with `oc` logged in. Two-step flow when the admin host can't reach AMD KDS:
#   1) run it once on a host with `oc` access  -> writes <OUT>/<hwid>/vcek.url for each URL
#      snphost emits. Some snphost builds emit only the local/default PSP and have no socket
#      selector; in that case, carry in the missing <OUT>/<hwid>/vcek.der files separately.
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

parse_hwid_from_url() {
  local url="$1" hwid
  hwid="$(echo "${url}" | sed -E 's#.*/v1/[^/]+/([^?]+).*#\1#' | tr 'A-Z' 'a-z')"
  [[ -n "${hwid}" && "${hwid}" != "${url}" ]] || die "could not parse HWID from URL: ${url}"
  [[ "${hwid}" =~ ^[0-9a-f]{128}$ ]] || die "parsed HWID is not 128 lowercase hex chars: ${hwid}"
  printf '%s\n' "${hwid}"
}

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

# Socket count is only an expectation check. snphost 1.12 has no socket selector, so never loop
# with a fake --socket flag; use every URL snphost emits, then require the carried bundle to have
# enough .der files for the host.
SOCKETS="$(oc debug "node/${NODE}" -- chroot /host lscpu 2>/dev/null \
            | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')"
[[ "${SOCKETS}" =~ ^[0-9]+$ ]] || die "could not read socket count from the node"
echo ">> ${NODE}: ${SOCKETS} socket(s)"

vcek_out="$(on_node "/tools/snphost show vcek-url" 2>&1)" || die "snphost show vcek-url failed: ${vcek_out}"
mapfile -t urls < <(grep -oE 'https://[^[:space:]]+' <<<"${vcek_out}" | sort -u)
[[ "${#urls[@]}" -gt 0 ]] || die "snphost show vcek-url returned no VCEK URLs"
echo ">> snphost emitted ${#urls[@]} VCEK URL(s)"

for url in "${urls[@]}"; do
  hwid="$(parse_hwid_from_url "${url}")"
  dir="${OUT}/${hwid}"; mkdir -p "${dir}"; echo "${url}" > "${dir}/vcek.url"
  echo ">> hwid ${hwid}"

  # Fetch the .der here if KDS is reachable; otherwise defer to the --download step.
  if [[ ! -s "${dir}/vcek.der" ]]; then
    if curl -fsS -m 8 -o /dev/null "https://${KDS_HOST}/" 2>/dev/null; then
      curl -fsSL "${url}" -o "${dir}/vcek.der"
    else
      echo "   KDS unreachable here — run \`$0 --download\` on a connected host, then re-run this."
      continue
    fi
  fi
done

mapfile -t ders < <(find "${OUT}" -mindepth 2 -maxdepth 2 -type f -name vcek.der 2>/dev/null | sort)
if [[ "${#ders[@]}" -lt "${SOCKETS}" ]]; then
  die "bundle has ${#ders[@]} VCEK DER file(s) but ${NODE} reports ${SOCKETS} socket(s). snphost has no --socket flag; add the missing ${OUT}/<hwid>/vcek.der file(s), then re-run."
fi
if [[ "${SOCKETS}" -gt 1 && "${#urls[@]}" -lt "${SOCKETS}" ]]; then
  echo "WARN: snphost emitted fewer URLs than socket count; trusting the carried bundle (${#ders[@]} DER file(s))."
fi

created=0
for der in "${ders[@]}"; do
  hwid="$(basename "$(dirname "${der}")" | tr 'A-F' 'a-f')"
  [[ "${hwid}" =~ ^[0-9a-f]{128}$ ]] || die "invalid HWID directory name for ${der}: ${hwid}"
  secret="vcek-snp-${created}"
  # Short secret names are required because the trustee operator uses secretName as a pod volume
  # name (63-char cap). The full HWID belongs in KbsConfig.mountPath, not in the secret name.
  oc create secret generic "${secret}" --from-file=vcek.der="${der}" \
     -n "${NS}" --dry-run=client -o yaml | oc apply -f -
  echo ">> ${secret}: ${hwid}"
  created=$((created+1))
done

echo
echo "Created/updated ${created} VCEK secret(s) in ${NS}."
echo "Next: reference each secret in KbsConfig.spec.kbsLocalCertCacheSpec (mountPath"
echo "  .../kds-store/vcek/<hwid>/vcek.der). VERIFY the .der carries the ARK/ASK chain or supply"
echo "  ASK/ARK separately. Confirm hwid dirs are LOWERCASE."
