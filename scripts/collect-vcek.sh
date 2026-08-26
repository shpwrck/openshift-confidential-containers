#!/usr/bin/env bash
# Air-gap VCEK collection for the Trustee OfflineStore (the customer sign-off gate).
# Generation-agnostic (dodges trustee bug #591 'Milan' hardcode). Re-runnable so it also
# serves the TCB-refresh case after a firmware update.
#
# AMD single- and multi-socket hosts use the same host-level collection workflow. Run the default
# command once per eligible host; socket enumeration, CPU pinning, and extra report collection are
# not required.
#
# DESIGN (see docs/design/engagement-design.md §4):
#   host-side:   snphost show vcek-url                    -> the host HWID + KDS URL
#   optional:    SNP attestation report -> --from-report  -> report-derived HWID + VCEK
#   connected:   download <url|report> -> vcek.der        (run where KDS is reachable)
#   air-gapped:  one short K8s secret per VCEK, mounted via KbsConfig.kbsLocalCertCacheSpec
#                at /opt/confidential-containers/attestation-service/kds-store/vcek/<lowercase-hwid>/vcek.der
#
# This script is hardware-bound; the collect + secret steps need `oc` logged into the node.
# Two-step flow when the admin host can't reach AMD KDS:
#   1) run it once with `oc` access  -> writes <OUT>/<hwid>/vcek.url for the host;
#   2) on a KDS-CONNECTED host, run `--download` (curls each .url -> vcek.der);
#   3) run it again with `oc` access (.der now present) -> creates one secret per hwid.
# When the host running step 1 IS internet-connected, all three happen in one pass.
#
# Usage:
#   ./scripts/collect-vcek.sh <node-name> [namespace]   # host hwid+url (+download if KDS) + secrets
#   ./scripts/collect-vcek.sh --download                # offline KDS download step only (no oc needed)
#   ./scripts/collect-vcek.sh --from-report <r.bin>...  # optional import from SNP report(s)
# Env: OUT=./vcek-bundle  TOOLS_IMG=...  KDS_HOST=kdsintf.amd.com  PROCESSOR=milan|genoa (for snpguest)
set -euo pipefail
# shellcheck source=scripts/lib/compat.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/compat.sh"

OUT="${OUT:-./vcek-bundle}"
TOOLS_IMG="${TOOLS_IMG:-quay.io/openshift_sandboxed_containers/coco-tools@sha256:89c219d2c7cb8359e8cc86605df1d31ce3be0f2565683b8bff882dba0c8e2605}"
PODMAN_AUTHFILE="${PODMAN_AUTHFILE:-/var/lib/kubelet/config.json}"
KDS_HOST="${KDS_HOST:-kdsintf.amd.com}"
PROCESSOR="${PROCESSOR:-}"
PATH="/usr/local/bin:${PATH}"
export PATH

if [[ -z "${KUBECONFIG:-}" && -r /opt/install/cluster-assets/auth/kubeconfig ]]; then
  export KUBECONFIG="/opt/install/cluster-assets/auth/kubeconfig"
fi

die() { echo "ERROR: $*" >&2; exit 1; }

# Stable, collision-free VCEK secret name: a readable hwid prefix + a hash of the FULL hwid. This
# MUST match seed-trustee-secrets.sh and apply-trustee.sh render_kbsconfig, which map this same name
# to the HWID mountPath. An HWID-derived name rather than a positional index means a TCB refresh or
# host replacement never renumbers existing secrets and cannot remap a KbsConfig entry. Hashing the
# full 64-byte CHIP_ID avoids prefix collisions. The name is <=63 chars because it becomes a Pod
# volume name; the full lowercase HWID remains in the verifier's mountPath.
vcek_secret_name() { printf 'vcek-snp-%s-%s\n' "${1:0:16}" "$(printf '%s' "$1" | sha256_stdin | cut -c1-16)"; }

parse_hwid_from_url() {
  local url="$1" hwid
  hwid="$(echo "${url}" | sed -E 's#.*/v1/[^/]+/([^?]+).*#\1#' | tr '[:upper:]' '[:lower:]')"
  [[ -n "${hwid}" && "${hwid}" != "${url}" ]] || die "could not parse HWID from URL: ${url}"
  [[ "${hwid}" =~ ^[0-9a-f]{128}$ ]] || die "parsed HWID is not 128 lowercase hex chars: ${hwid}"
  printf '%s\n' "${hwid}"
}

# The SNP attestation report carries the chip's CHIP_ID as 64 bytes at a FIXED offset 0x1A0 (416).
# That value IS the hwid Trustee looks the VCEK up by — read it straight from the binary (stable
# ABI) rather than scraping `snpguest display report` text.
hwid_from_report() {
  local report="$1" hwid
  [[ -s "${report}" ]] || die "report not found or empty: ${report}"
  # od (coreutils, always present — unlike xxd); -v is REQUIRED or od collapses repeated bytes to '*'.
  hwid="$(dd if="${report}" bs=1 skip=416 count=64 2>/dev/null | od -An -v -tx1 | tr -d ' \n' | tr 'A-F' 'a-f')"
  [[ "${hwid}" =~ ^[0-9a-f]{128}$ ]] \
    || die "no 128-hex CHIP_ID at offset 0x1A0 in ${report} — is it a raw SNP attestation report (snpguest report ...)?"
  printf '%s\n' "${hwid}"
}

kds_reachable() { curl -fsS -m 8 -o /dev/null "https://${KDS_HOST}/" 2>/dev/null; }

# Atomic der write: an interrupted curl must not leave a truncated vcek.der that the `[[ -s ]]`
# guards would treat as complete on the next run.
fetch_der_from_url() { local url="$1" dest="$2"; curl -fsSL "${url}" -o "${dest}.tmp" && mv -f "${dest}.tmp" "${dest}"; }

require_writable_bundle_dir() {
  local dir="$1"
  # A prior privileged/root collection can leave OUT/<hwid> root-owned; fail with a clear,
  # actionable message instead of the raw "Permission denied" a redirect would throw.
  [[ -w "${dir}" ]] || die "bundle dir not writable: ${dir} (likely root-owned from a prior run — run: sudo chown -R \"\$(id -un)\" \"${OUT}\")"
}

# Create one secret per <OUT>/<hwid>/vcek.der, named by vcek_secret_name (stable, hwid-derived).
create_secrets() {
  local ns="$1" der hwid name created=0
  ders=()
  while IFS= read -r der_line; do ders+=("$der_line"); done < <(find "${OUT}" -mindepth 2 -maxdepth 2 -type f -name vcek.der 2>/dev/null | sort)
  [[ "${#ders[@]}" -gt 0 ]] || { echo "No vcek.der files under ${OUT} yet — nothing to seed."; return 0; }
  for der in "${ders[@]}"; do
    hwid="$(basename "$(dirname "${der}")" | tr 'A-F' 'a-f')"
    [[ "${hwid}" =~ ^[0-9a-f]{128}$ ]] || die "invalid HWID directory name for ${der}: ${hwid}"
    name="$(vcek_secret_name "${hwid}")"
    oc create secret generic "${name}" --from-file=vcek.der="${der}" \
       -n "${ns}" --dry-run=client -o yaml | oc apply -f -
    echo ">> ${name}: ${hwid}"
    created=$((created+1))
  done
  echo
  echo "Created/updated ${created} VCEK secret(s) in ${ns}."
  echo "Each is referenced by KbsConfig.spec.kbsLocalCertCacheSpec (apply-trustee.sh renders one"
  echo "  {secretName, mountPath .../kds-store/vcek/<hwid>/vcek.der} entry per hwid). VERIFY the"
  echo "  .der carries the ARK/ASK chain or supply ASK/ARK separately; hwid dirs must be LOWERCASE."
}

# --- download-only mode: curl every collected .url on a KDS-connected host -----------------
if [[ "${1:-}" == "--download" ]]; then
  shopt -s nullglob
  urls=("${OUT}"/*/vcek.url)
  [[ ${#urls[@]} -gt 0 ]] || die "no ${OUT}/*/vcek.url found — run the collect step (with oc) first"
  for u in "${urls[@]}"; do
    d="$(dirname "$u")"
    echo ">> downloading VCEK for $(basename "$d")"
    fetch_der_from_url "$(cat "$u")" "${d}/vcek.der"
  done
  echo "Downloaded ${#urls[@]} VCEK cert(s). Carry ${OUT}/ into the air gap and re-run with <node> to create secrets."
  exit 0
fi

# --- --from-report mode: optionally import a VCEK from an SNP attestation report -------------
# Run on a host that can reach AMD KDS and has snpguest (e.g. the coco-tools container). Reads the
# report's CHIP_ID and reported TCB, fetches the matching VCEK, and stages it in the bundle. This is
# an alternate import/diagnostic path, not an extra multi-socket installation step.
if [[ "${1:-}" == "--from-report" ]]; then
  shift
  [[ $# -gt 0 ]] || die "usage: collect-vcek.sh --from-report <report.bin> [more-reports...]"
  mkdir -p "${OUT}"
  for report in "$@"; do
    hwid="$(hwid_from_report "${report}")"
    dir="${OUT}/${hwid}"; mkdir -p "${dir}"; require_writable_bundle_dir "${dir}"
    # keep the report next to the cert for provenance (skip if it already IS that file, so a re-run
    # of `--from-report OUT/<hwid>/report.bin` doesn't hit cp's "same file" error)
    [[ "${report}" -ef "${dir}/report.bin" ]] || cp -f "${report}" "${dir}/report.bin"
    if [[ -s "${dir}/vcek.der" ]]; then
      echo ">> ${hwid}: vcek.der already present — kept"
    elif command -v snpguest >/dev/null && kds_reachable; then
      tmpc="$(mktemp -d)"
      snpguest_args=(fetch vcek der "${tmpc}" "${report}")
      [[ -n "${PROCESSOR}" ]] && snpguest_args+=(-p "${PROCESSOR}")
      snpguest "${snpguest_args[@]}" >/dev/null 2>&1 \
        || die "snpguest fetch vcek failed for ${report} (try PROCESSOR=milan|genoa; confirm KDS reachable)"
      # snpguest writes vcek.der into the certs dir; take it (fall back to any *.der it produced).
      src="${tmpc}/vcek.der"; [[ -s "${src}" ]] || src="$(find "${tmpc}" -name '*.der' -type f | head -1)"
      [[ -s "${src}" ]] || die "snpguest produced no VCEK .der in ${tmpc} for ${report}"
      mv -f "${src}" "${dir}/vcek.der"; rm -rf "${tmpc}"
      echo ">> ${hwid}: fetched VCEK from report"
    else
      echo ">> ${hwid}: staged report.bin — no snpguest+KDS here; carry ${dir}/report.bin to a"
      echo "   host with snpguest + KDS and re-run \`$0 --from-report ${dir}/report.bin\`."
    fi
  done
  # Create/refresh secrets if we have oc access so an imported report is wired in immediately.
  # Namespace comes from NS env (default trustee-operator-system) — the positional args are reports.
  if command -v oc >/dev/null && oc whoami >/dev/null 2>&1; then
    create_secrets "${NS:-trustee-operator-system}"
  else
    echo "No cluster access here — carry ${OUT}/ into the air gap and run \`$0 <node>\` to create secrets."
  fi
  exit 0
fi

# --- default collect mode -----------------------------------------------------------------
NODE="${1:?usage: collect-vcek.sh <node-name> [namespace]   |   --download   |   --from-report <r.bin>...}"
NS="${2:-trustee-operator-system}"
command -v oc >/dev/null || die "oc not on PATH"
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
mkdir -p "${OUT}"

# Run a command in a privileged coco-tools container on the node, via `oc debug node`.
on_node() {  # on_node <shell-command-string>
  oc debug "node/${NODE}" -- chroot /host \
    podman run --rm --authfile "${PODMAN_AUTHFILE}" --privileged -v /dev:/dev "${TOOLS_IMG}" bash -c "$1"
}

# Collect the host VCEK using the standard snphost interface.
vcek_out="$(on_node "/tools/snphost show vcek-url" 2>&1)" || die "snphost show vcek-url failed: ${vcek_out}"
urls=()
while IFS= read -r url_line; do urls+=("$url_line"); done < <(grep -oE 'https://[^[:space:]]+' <<<"${vcek_out}" | sort -u)
[[ "${#urls[@]}" -gt 0 ]] || die "snphost show vcek-url returned no VCEK URL: ${vcek_out}"
for url in "${urls[@]}"; do
  hwid="$(parse_hwid_from_url "${url}")"
  dir="${OUT}/${hwid}"; mkdir -p "${dir}"; require_writable_bundle_dir "${dir}"
  echo "${url}" > "${dir}/vcek.url"
  echo ">> host hwid ${hwid}"
  if [[ ! -s "${dir}/vcek.der" ]]; then
    if kds_reachable; then
      fetch_der_from_url "${url}" "${dir}/vcek.der"
    else
      echo "   KDS unreachable here — run \`$0 --download\` on a connected host, then re-run this."
    fi
  fi
done

create_secrets "${NS}"
