#!/usr/bin/env bash
# Generate RVPS reference values with Veritas. Hardware-bound: run on the TARGET hardware
# (rig proves the procedure; production metal regenerates the data). One run per distinct
# hardware config (CPU family + firmware). See docs/design/engagement-design.md §4.
#
# Runs the coco-tools `veritas` generator over your initdata and emits an RVPS reference-values
# ConfigMap payload in the Trustee 1.2 reference_value format.
# Publish through apply-trustee.sh configure after reviewing the selected CPU policy.
#
# Where it runs: by default `podman` on THIS host (point it at the node, or copy initdata to the
# node and run there). Set NODE=<name> to run it on the cluster node via `oc debug node` instead
# — use that if veritas needs to read the live firmware/TCB rather than just the initdata.
#
# Usage:    TEE=snp ./scripts/gen-rvps-veritas.sh             # local podman
#           TEE=snp NODE=<node> ./scripts/gen-rvps-veritas.sh  # run on the node via oc debug
# Env:
#   TEE=snp
#   OCP_VERSION=<BOM version>                         # repeat with spaces for multiple versions
#   PULL_SECRET=$HOME/.local/state/coco/pull-secret.json
#   INITDATA=$COCO_STATE_DIR/initdata.toml
#   OUT=$COCO_STATE_DIR/rvps-snp.yaml
#   DEBUG_IMAGE=<cached-image>                     # NODE mode only, avoids public support-tools
#   REGISTRIES_CONF=./registries.conf              # mounted as /etc/containers/registries.conf
#   REGISTRY_CERTS_DIR=/etc/containers/certs.d     # NODE mode path must exist on the node
#   VERITAS_OC_WRAPPER=./oc                         # mounted before /usr/local/bin/oc in PATH
#   VERITAS_EXTRA_ARGS="--kernel-cmdline ..."
#
# DISCONNECTED (air-gap) RECIPE — proven on the rig 2026-07-01. Veritas verifies the OCP release
# payload, and that verification does a registry TAGS-LIST on quay.io/openshift-release-dev, which
# `registries.conf` mirroring does NOT redirect (mirrors cover digest/manifest pulls, not tag
# enumeration). So a mirror-only PULL_SECRET fails 401 at "Verifying release payload". Run this on
# the BASTION (which has quay egress) with a MERGED authfile:
#   jq -s '{auths:(.[0].auths + .[1].auths)}' pull-secret.json ~/.docker/config.json > authfile.json
# i.e. RH/quay creds (for the tags-list) PLUS mirror creds (for the digest pulls redirected by
# REGISTRIES_CONF). Keep the BOM's canonical TOOLS_IMG identity; configure the
# host's digest mirror mapping for the outer pull and stage the mirror CA under
# REGISTRY_CERTS_DIR=<dir>/<mirror-host:port>/ca.crt. Then the tags-list authenticates to quay while
# the heavy component-image pulls come from the mirror.
set -euo pipefail
command -v python3 >/dev/null || { echo 'ERROR: Python 3.12+ is required on the controller/bastion' >&2; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else "ERROR: Python 3.12+ is required on the controller/bastion")'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$REPO_ROOT/scripts/lib/release.sh"
load_release_defaults
TRUSTEE_NAME="${TRUSTEE_NAME:-trustee-config}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"

TEE="${TEE:-snp}"
TOOLS_IMG="${TOOLS_IMG:?resolved coco-tools image is required}"
OCP_VERSION="${OCP_VERSION:?OCP_VERSION is required}"
PULL_SECRET="${PULL_SECRET:-${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}/credentials/pull-secret.json}"
COCO_STATE_DIR="${COCO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openshift-confidential-containers}"
INITDATA="${INITDATA:-${COCO_STATE_DIR}/initdata.toml}"
OUT="${OUT:-${COCO_STATE_DIR}/rvps-${TEE}.yaml}"
NODE="${NODE:-}"
DEBUG_IMAGE="${DEBUG_IMAGE:-}"
REGISTRIES_CONF="${REGISTRIES_CONF:-}"
REGISTRY_CERTS_DIR="${REGISTRY_CERTS_DIR:-}"
VERITAS_OC_WRAPPER="${VERITAS_OC_WRAPPER:-}"
VERITAS_EXTRA_ARGS="${VERITAS_EXTRA_ARGS:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v python3 >/dev/null || die "python3 is required for target RVPS validation"
require_resolved_release
[[ "${TEE}" == "snp" ]] || die "this workflow targets AMD SEV-SNP; set TEE=snp"
[[ -s "${INITDATA}" ]] || die "initdata not found: ${INITDATA} (set INITDATA=...)"
[[ -s "${PULL_SECRET}" ]] || die "pull secret not found: ${PULL_SECRET} (set PULL_SECRET=...)"
[[ -n "${OCP_VERSION}" ]] || die "OCP_VERSION is required for Veritas baremetal mode"
[[ -z "${REGISTRIES_CONF}" || -s "${REGISTRIES_CONF}" ]] || die "REGISTRIES_CONF not found: ${REGISTRIES_CONF}"
[[ -z "${REGISTRY_CERTS_DIR}" || -d "${REGISTRY_CERTS_DIR}" || -n "${NODE}" ]] || die "REGISTRY_CERTS_DIR not found: ${REGISTRY_CERTS_DIR}"
[[ -z "${VERITAS_OC_WRAPPER}" || -s "${VERITAS_OC_WRAPPER}" ]] || die "VERITAS_OC_WRAPPER not found: ${VERITAS_OC_WRAPPER}"

# Portable base64 helpers for HOST-side use. `base64 -w0` (wrap) and `-d` (decode) are GNU-coreutils
# flags; NODE mode can be launched from a non-GNU (BSD/macOS) workstation since it needs only `oc`.
# (The node-side base64 calls inside the heredoc run on RHCOS = GNU, so they keep -w0/-d.)
b64() { base64 | tr -d '\n'; }                 # encode stdin to a single line (replaces `base64 -w0`)
if printf '' | base64 -d >/dev/null 2>&1; then _b64d_flag='-d'; else _b64d_flag='-D'; fi
b64d() { base64 "${_b64d_flag}"; }             # decode stdin (GNU `-d` / BSD `-D`)

umask 077
# Keep credential-bearing temporary node scripts outside the checkout regardless of TMPDIR.
export TMPDIR=/tmp
python3 - "$REPO_ROOT" "$PULL_SECRET" "$OUT" <<'CHECK'
import pathlib, sys
repo = pathlib.Path(sys.argv[1]).resolve()
for item in sys.argv[2:]:
    path = pathlib.Path(item).resolve()
    if path == repo or repo in path.parents or str(path).casefold() == '/mnt/c/homelab' or str(path).casefold().startswith('/mnt/c/homelab/'):
        raise SystemExit("ERROR: pull secret and RVPS output must be outside the checkout and Homelab")
CHECK
mkdir -p "$(dirname "$OUT")"
cleanup_paths=()
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  local path
  for path in ${cleanup_paths[@]+"${cleanup_paths[@]}"}; do
    [[ -n "${path}" ]] && rm -rf "${path}"
  done
}
trap cleanup EXIT
raw_output="$(mktemp /tmp/coco-rvps-raw.XXXXXX)"
cleanup_paths+=("$raw_output")

veritas_args=(veritas --platform baremetal --tee "${TEE}" --authfile /pull-secret.json --initdata /initdata.toml)
for version in ${OCP_VERSION}; do
  veritas_args+=(--ocp-version "${version}")
done
if [[ -n "${VERITAS_EXTRA_ARGS}" ]]; then
  read -r -a extra_args <<< "${VERITAS_EXTRA_ARGS}"
  veritas_args+=(${extra_args[@]+"${extra_args[@]}"})
fi

copy_veritas_output() {
  local source_dir="$1" dest="$2" source
  source="${source_dir}/rvps-reference-values.yaml"
  [[ -s "${source}" ]] || die "veritas output missing: ${source}"
  cp "${source}" "${dest}"
}

if [[ -n "${NODE}" ]]; then
  # Stream protected input through stdin; never embed credentials in a debug Pod's command.
  # shellcheck source=scripts/lib/cluster-context.sh
  source "$REPO_ROOT/scripts/lib/cluster-context.sh"
  load_worker_context
  command -v oc >/dev/null || die "oc not on PATH (needed for NODE mode)"
  worker_oc whoami >/dev/null 2>&1 || die "not logged into WORKER_CONTEXT"
  [[ "$DEBUG_IMAGE" =~ @sha256:[a-f0-9]{64}$ ]] || die "NODE mode requires a mirrored, immutable DEBUG_IMAGE"
  echo ">> running veritas (${TEE}) on node ${NODE}"
  capture="$(mktemp "${OUT}.log.XXXXXX")"
  node_script="$(mktemp)"
  cleanup_paths+=("${node_script}")
  b64_ps="$(b64 < "${PULL_SECRET}")"
  b64_id="$(b64 < "${INITDATA}")"
  b64_registries=""
  b64_oc_wrapper=""
  [[ -n "${REGISTRIES_CONF}" ]] && b64_registries="$(b64 < "${REGISTRIES_CONF}")"
  [[ -n "${VERITAS_OC_WRAPPER}" ]] && b64_oc_wrapper="$(b64 < "${VERITAS_OC_WRAPPER}")"
  {
    printf 'set -euo pipefail\numask 077\n'
    printf 'b64_ps=%q\nb64_id=%q\nb64_registries=%q\nb64_oc_wrapper=%q\n' "$b64_ps" "$b64_id" "$b64_registries" "$b64_oc_wrapper"
    printf 'REGISTRY_CERTS_DIR=%q\nTOOLS_IMG=%q\n' "$REGISTRY_CERTS_DIR" "$TOOLS_IMG"
    printf 'veritas_args=('
    printf '%q ' "${veritas_args[@]}"
    printf ')\n'
    cat <<'NODE_SCRIPT'
t=$(mktemp -d)
trap 'rm -rf "${t}"' EXIT
mkdir -p "${t}/out"
printf '%s' "$b64_ps" | base64 -d > "${t}/pull-secret.json"
printf '%s' "$b64_id" | base64 -d > "${t}/initdata.toml"
podman_args=(run --rm --privileged -v /dev:/dev -v "${t}:/work:z" -v "${t}/pull-secret.json:/pull-secret.json:ro,z" -v "${t}/initdata.toml:/initdata.toml:ro,z")
if [[ -n "$b64_registries" ]]; then
  printf '%s' "$b64_registries" | base64 -d > "${t}/registries.conf"
  podman_args+=(-v "${t}/registries.conf:/etc/containers/registries.conf:ro,z")
fi
if [[ -n "$REGISTRY_CERTS_DIR" ]]; then
  [[ -d "$REGISTRY_CERTS_DIR" ]] || { echo "ERROR: registry certificate directory not found on node" >&2; exit 1; }
  podman_args+=(-v "${REGISTRY_CERTS_DIR}:/etc/containers/certs.d:ro,z")
fi
if [[ -n "$b64_oc_wrapper" ]]; then
  mkdir -p "${t}/bin"
  printf '%s' "$b64_oc_wrapper" | base64 -d > "${t}/bin/oc"
  chmod +x "${t}/bin/oc"
  podman_args+=(-v "${t}/bin:/veritas-bin:ro,z" -e PATH="/veritas-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
fi
podman "${podman_args[@]}" "$TOOLS_IMG" "${veritas_args[@]}" -o /work/out >&2
printf '__VERITAS_RVPS_B64_BEGIN__\n'
base64 -w0 "${t}/out/rvps-reference-values.yaml"
printf '\n__VERITAS_RVPS_B64_END__\n'
NODE_SCRIPT
  } > "$node_script"
  debug_args=(debug --no-stdin=false --no-tty "node/${NODE}" --image="$DEBUG_IMAGE" -- chroot /host bash -s)
  if ! worker_oc "${debug_args[@]}" < "$node_script" > "$capture" 2>&1; then
    die "Veritas failed on selected node; inspect protected log $capture"
  fi
  if ! awk '/^__VERITAS_RVPS_B64_BEGIN__$/ { emit = 1; next } /^__VERITAS_RVPS_B64_END__$/ { emit = 0 } emit { print }' "$capture" | b64d > "$raw_output"; then
    die "could not extract Veritas output; inspect protected log $capture"
  fi

else
  command -v podman >/dev/null || die "podman not on PATH (or set NODE=<node> to run on the cluster node)"
  if ! podman image exists "${TOOLS_IMG}"; then
    echo "WARN: coco-tools image not present locally (${TOOLS_IMG}); podman will try to pull it." >&2
    echo "      On a disconnected bastion this OUTER pull is NOT redirected by REGISTRIES_CONF (that" >&2
    echo "      only applies INSIDE the container) — pre-pull or mirror it and set TOOLS_IMG=<mirror ref>." >&2
  fi
  echo ">> running veritas (${TEE}) locally via podman"
  out_parent="$(cd "$(dirname "${OUT}")" && pwd)"
  out_base="$(basename "${OUT}")"
  veritas_out_dir="$(mktemp -d "${out_parent}/.${out_base}.veritas.XXXXXX")"
  cleanup_paths+=("${veritas_out_dir}")
  podman_args=(run --rm --privileged
    -v "${PULL_SECRET}:/pull-secret.json:ro,z"
    -v "${INITDATA}:/initdata.toml:ro,z"
    -v "${veritas_out_dir}:/veritas-out:z")
  [[ -n "${REGISTRIES_CONF}" ]] && podman_args+=(-v "${REGISTRIES_CONF}:/etc/containers/registries.conf:ro,z")
  [[ -n "${REGISTRY_CERTS_DIR}" ]] && podman_args+=(-v "${REGISTRY_CERTS_DIR}:/etc/containers/certs.d:ro,z")
  # Stage the oc wrapper in the PARENT shell (NOT a command-substitution subshell, whose
  # cleanup_paths append would be discarded → leaked temp dir). The wrapper shadows the `oc`
  # that veritas calls internally to fetch the OCP release, so a disconnected run can redirect
  # that to a mirror / cached payload.
  if [[ -n "${VERITAS_OC_WRAPPER}" ]]; then
    wrapper_stage="$(mktemp -d)"
    cleanup_paths+=("${wrapper_stage}")
    cp "${VERITAS_OC_WRAPPER}" "${wrapper_stage}/oc"
    chmod +x "${wrapper_stage}/oc"
    podman_args+=(-v "${wrapper_stage}:/veritas-bin:ro,z" -e PATH="/veritas-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  fi
  podman "${podman_args[@]}" "${TOOLS_IMG}" "${veritas_args[@]}" -o /veritas-out
  copy_veritas_output "${veritas_out_dir}" "${raw_output}"
fi

[[ -s "${raw_output}" ]] || die "veritas produced no output"
validated_output="$(mktemp /tmp/coco-rvps-validated.XXXXXX)"
cleanup_paths+=("$validated_output")
python3 "$REPO_ROOT/scripts/lib/trustee_config.py" rvps --file "$raw_output" \
  --name "${TRUSTEE_RVPS_CONFIGMAP:-${TRUSTEE_NAME}-rvps-reference-values}" \
  --namespace "$TRUSTEE_NS" > "$validated_output"
# Only replace the caller's last known-good output after full parse/expiry/format validation.
python3 - "$validated_output" "$OUT" <<'PUBLISH'
import os, pathlib, sys, tempfile
source, output = map(pathlib.Path, sys.argv[1:])
fd, temporary = tempfile.mkstemp(prefix='.rvps-', dir=output.parent)
try:
    with os.fdopen(fd, 'wb') as stream:
        stream.write(source.read_bytes())
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PUBLISH
echo "Wrote validated Trustee 1.2 RVPS ConfigMap: ${OUT}."
echo "Next: review the records against the selected CPU policy, then publish with Trustee configure."
echo "Generation does not publish reference values or prove appraisal; run paired reference-value proofs."
exit 0
