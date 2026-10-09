#!/usr/bin/env bash
# Separate collection/download/publication. No mode uses an ambient cluster context.
# <node> collects URLs from WORKER_CONTEXT; --download and --from-report are local.
# --seed [namespace] is the only mode that writes certificates to TRUSTEE_CONTEXT.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/compat.sh"
source "$REPO_ROOT/scripts/lib/release.sh"
source "$REPO_ROOT/scripts/lib/cluster-context.sh"
load_release_defaults
VCEK_BUNDLE="${VCEK_BUNDLE:-${OUT:-${COCO_STATE_DIR:-${HOME}/.local/state/openshift-confidential-containers}/vcek-bundle}}"
OUT="$VCEK_BUNDLE"
HELPER="$REPO_ROOT/scripts/lib/vcek_bundle.py"
PODMAN_AUTHFILE="${PODMAN_AUTHFILE:-/var/lib/kubelet/config.json}"
KDS_HOST="${KDS_HOST:-kdsintf.amd.com}"
PROCESSOR="${PROCESSOR:-}"
die() { echo "ERROR: $*" >&2; exit 2; }
# Reports and publication state must stay outside this shared Homelab checkout.
OUT="$(python3 - "$OUT" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]).expanduser().resolve(); repo=Path(sys.argv[2]).resolve()
if p == repo or repo in p.parents or str(p).lower() == '/mnt/c/homelab' or str(p).lower().startswith('/mnt/c/homelab/'):
    raise SystemExit('ERROR: VCEK_BUNDLE must be outside the checkout and /mnt/c/Homelab')
print(p)
PY
)"
export VCEK_BUNDLE="$OUT"

vcek_secret_name() { printf 'vcek-snp-%s-%s\n' "${1:0:16}" "$(printf '%s' "$1" | sha256_stdin | cut -c1-16)"; }
parse_hwid_from_url() {
  python3 - "$1" "$KDS_HOST" <<'PY'
from urllib.parse import urlsplit
import re,sys
u=urlsplit(sys.argv[1]); parts=u.path.split('/')
if u.scheme!='https' or u.hostname!=sys.argv[2] or u.username or u.password or len(parts)!=5 or parts[1:3]!=['vcek','v1'] or not re.fullmatch('[0-9a-fA-F]{128}',parts[4]):
    raise SystemExit('ERROR: expected an HTTPS AMD KDS VCEK URL for the selected host')
print(parts[4].lower())
PY
}
hwid_from_report() {
  local hwid
  [[ -s "$1" ]] || die "missing report: $1"
  hwid="$(dd if="$1" bs=1 skip=416 count=64 2>/dev/null | od -An -v -tx1 | tr -d ' \n' | tr 'A-F' 'a-f')"
  [[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "raw SNP report has no complete CHIP_ID at offset 416"
  printf '%s\n' "$hwid"
}
# The service root may return 404 while certificate endpoints work. This is
# connectivity only; fetch_der validates the actual response before publication.
kds_reachable() { curl -sS -m 8 -o /dev/null "https://${KDS_HOST}/" 2>/dev/null; }
fetch_der() {
  local url="$1" dir="$2" source_hash="$3" temp
  parse_hwid_from_url "$url" >/dev/null
  temp="$(mktemp "$dir/download.XXXXXX")"
  if curl -fsSL --max-time 120 "$url" -o "$temp" && python3 "$HELPER" publish "$dir" --certificate "$temp" --source-sha256 "$source_hash"; then
    rm -f "$temp"
  else
    rm -f "$temp"; die "download or certificate/provenance validation failed; previous certificate was preserved"
  fi
}

case "${1:-}" in
  --seed)
    [[ -n "${TRUSTEE_CONTEXT:-}" ]] || die "--seed requires explicit TRUSTEE_CONTEXT"
    require_resolved_release
    ns="${2:-${NS:-trustee-operator-system}}"
    command -v oc >/dev/null || die "oc not on PATH"
    trustee_oc whoami >/dev/null
    shopt -s nullglob
    ders=("$OUT"/*/vcek.der)
    [[ -n "${ders[0]+present}" ]] || die "no certificates to seed under VCEK_BUNDLE"
    # Validate the entire set before the first write, including URL/report changes.
    for der in "${ders[@]}"; do
      hwid="$(basename "$(dirname "$der")")"
      [[ "$hwid" =~ ^[0-9a-f]{128}$ ]] || die "invalid HWID directory"
      python3 "$HELPER" current "$(dirname "$der")"
    done
    for der in "${ders[@]}"; do
      hwid="$(basename "$(dirname "$der")")"; name="$(vcek_secret_name "$hwid")"
      trustee_oc -n "$ns" create secret generic "$name" --from-file=vcek.der="$der" --dry-run=client -o yaml | trustee_oc -n "$ns" apply -f -
    done
    echo "Published ${#ders[@]} certificate(s) to explicit Trustee context; attestation remains to be verified."
    ;;
  --download)
    shopt -s nullglob
    urls=("$OUT"/*/vcek.url)
    [[ -n "${urls[0]+present}" ]] || die "no collected VCEK URLs under VCEK_BUNDLE"
    for url_file in "${urls[@]}"; do
      dir="$(dirname "$url_file")"
      source_hash="$(python3 "$HELPER" request "$dir" --kind url --source "$url_file")"
      fetch_der "$(cat "$url_file")" "$dir" "$source_hash"
    done
    echo "Downloaded and validated certificates. Use --seed with explicit TRUSTEE_CONTEXT to publish."
    ;;
  --from-report)
    shift; [[ $# -gt 0 ]] || die "--from-report requires raw SNP report files"
    for report in "$@"; do
      hwid="$(hwid_from_report "$report")"; dir="$OUT/$hwid"
      source_hash="$(python3 "$HELPER" request "$dir" --kind report --source "$report")"
      if python3 "$HELPER" current "$dir" >/dev/null 2>&1; then
        echo "Certificate matches the unchanged report and validity window."
      elif command -v snpguest >/dev/null && kds_reachable; then
        tmp="$(mktemp -d)"; args=(fetch vcek der "$tmp" "$dir/report.bin")
        [[ -z "$PROCESSOR" ]] || args+=(-p "$PROCESSOR")
        if snpguest "${args[@]}" && python3 "$HELPER" publish "$dir" --certificate "$tmp/vcek.der" --source-sha256 "$source_hash"; then rm -rf "$tmp";
        else rm -rf "$tmp"; die "report-based VCEK fetch/validation failed"; fi
      else
        echo "Report staged; current certificate unavailable. Transfer to a connected snpguest host and repeat --from-report."
      fi
    done
    echo "No Secrets were changed. Publish separately with --seed and TRUSTEE_CONTEXT."
    ;;
  *)
    NODE="${1:?usage: collect-vcek.sh <node> | --download | --from-report <report>... | --seed [namespace]}"
    load_worker_context
    require_resolved_release
    command -v oc >/dev/null || die "oc not on PATH"
    worker_oc whoami >/dev/null
    output="$(worker_oc debug "node/$NODE" -- chroot /host podman run --rm --authfile "$PODMAN_AUTHFILE" --privileged -v /dev:/dev "$TOOLS_IMG" /tools/snphost show vcek-url 2>&1)" || die "snphost collection failed"
    urls=(); while IFS= read -r url; do urls+=("$url"); done < <(grep -oE 'https://[^[:space:]]+' <<<"$output" | sort -u)
    [[ -n "${urls[0]+present}" ]] || die "snphost returned no VCEK URL"
    for url in "${urls[@]}"; do
      hwid="$(parse_hwid_from_url "$url")"; dir="$OUT/$hwid"; mkdir -p "$dir"
      tmp="$(mktemp "$dir/url.XXXXXX")"; printf '%s\n' "$url" > "$tmp"
      source_hash="$(python3 "$HELPER" request "$dir" --kind url --source "$tmp")"; rm -f "$tmp"
      if python3 "$HELPER" current "$dir" >/dev/null 2>&1; then
        echo "Certificate matches unchanged host URL/TCB input and validity window."
      elif kds_reachable; then fetch_der "$url" "$dir" "$source_hash";
      else echo "URL collected; certificate missing/stale. Transfer bundle to a connected host and run --download."; fi
    done
    echo "Collection finished; no Secrets were changed. Use --seed with TRUSTEE_CONTEXT after download."
    ;;
esac
