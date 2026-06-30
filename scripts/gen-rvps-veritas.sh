#!/usr/bin/env bash
# Generate RVPS reference values with Veritas. Hardware-bound: run on the TARGET hardware
# (rig proves the procedure; production metal regenerates the data). One run per distinct
# hardware config (CPU family + firmware). See docs/design/engagement-design.md §4.
#
# Runs the coco-tools `veritas` generator over your initdata and emits an RVPS reference-values
# YAML to merge into the `rvps-reference-values` ConfigMap (gitops/base/trustee/kbsconfig.yaml).
#
# Where it runs: by default `podman` on THIS host (point it at the node, or copy initdata to the
# node and run there). Set NODE=<name> to run it on the cluster node via `oc debug node` instead
# — use that if veritas needs to read the live firmware/TCB rather than just the initdata.
#
# Usage:    TEE=snp ./scripts/gen-rvps-veritas.sh             # local podman
#           TEE=snp NODE=<node> ./scripts/gen-rvps-veritas.sh  # run on the node via oc debug
# Env:
#   TEE=snp|tdx
#   OCP_VERSION="4.20.18"                         # repeat with spaces for multiple versions
#   PULL_SECRET=./pull-secret.json
#   INITDATA=./initdata-flavour-b.toml
#   OUT=./rvps-<tee>.yaml
#   DEBUG_IMAGE=<cached-image>                     # NODE mode only, avoids public support-tools
#   REGISTRIES_CONF=./registries.conf              # mounted as /etc/containers/registries.conf
#   REGISTRY_CERTS_DIR=/etc/containers/certs.d     # NODE mode path must exist on the node
#   VERITAS_OC_WRAPPER=./oc                         # mounted before /usr/local/bin/oc in PATH
#   VERITAS_EXTRA_ARGS="--kernel-cmdline ..."
set -euo pipefail

TEE="${TEE:-snp}"
TOOLS_IMG="${TOOLS_IMG:-quay.io/openshift_sandboxed_containers/coco-tools@sha256:89c219d2c7cb8359e8cc86605df1d31ce3be0f2565683b8bff882dba0c8e2605}"
OCP_VERSION="${OCP_VERSION:-4.20.18}"
PULL_SECRET="${PULL_SECRET:-./pull-secret.json}"
INITDATA="${INITDATA:-./initdata-flavour-b.toml}"
OUT="${OUT:-./rvps-${TEE}.yaml}"
NODE="${NODE:-}"
DEBUG_IMAGE="${DEBUG_IMAGE:-}"
REGISTRIES_CONF="${REGISTRIES_CONF:-}"
REGISTRY_CERTS_DIR="${REGISTRY_CERTS_DIR:-}"
VERITAS_OC_WRAPPER="${VERITAS_OC_WRAPPER:-}"
VERITAS_EXTRA_ARGS="${VERITAS_EXTRA_ARGS:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "${TEE}" == "snp" || "${TEE}" == "tdx" ]] || die "TEE must be 'snp' or 'tdx' (got '${TEE}')"
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

cleanup_paths=()
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  local path
  for path in "${cleanup_paths[@]}"; do
    [[ -n "${path}" ]] && rm -rf "${path}"
  done
}
trap cleanup EXIT

veritas_args=(veritas --platform baremetal --tee "${TEE}" --authfile /pull-secret.json --initdata /initdata.toml)
for version in ${OCP_VERSION}; do
  veritas_args+=(--ocp-version "${version}")
done
if [[ -n "${VERITAS_EXTRA_ARGS}" ]]; then
  read -r -a extra_args <<< "${VERITAS_EXTRA_ARGS}"
  veritas_args+=("${extra_args[@]}")
fi

copy_veritas_output() {
  local source_dir="$1" dest="$2" source
  source="${source_dir}/rvps-reference-values.yaml"
  [[ -s "${source}" ]] || die "veritas output missing: ${source}"
  cp "${source}" "${dest}"
}

if [[ -n "${NODE}" ]]; then
  # Run on the node: stage inputs into the debug pod, run podman there, stream the YAML back.
  command -v oc >/dev/null || die "oc not on PATH (needed for NODE mode)"
  oc whoami >/dev/null 2>&1 || die "not logged into a cluster"
  [[ -n "${DEBUG_IMAGE}" ]] || echo "WARN: DEBUG_IMAGE unset — 'oc debug' uses the default public support-tools image; on a disconnected cluster set DEBUG_IMAGE=<mirrored image>." >&2
  echo ">> running veritas (${TEE}) on node ${NODE}"
  capture="$(mktemp)"
  node_script="$(mktemp)"
  cleanup_paths+=("${capture}" "${node_script}")
  # NODE mode has no clean way to copy files in/out of an ephemeral `oc debug` pod, and the pod's
  # stdout is interleaved with debug chatter. So: base64-INJECT the inputs + node script into the
  # pod, and FENCE the YAML output between __VERITAS_RVPS_B64_*__ markers so it can be awk-extracted
  # cleanly from the noisy stream (decoded by the awk + b64d below).
  b64_ps="$(b64 < "${PULL_SECRET}")"
  b64_id="$(b64 < "${INITDATA}")"
  b64_registries=""
  b64_oc_wrapper=""
  [[ -n "${REGISTRIES_CONF}" ]] && b64_registries="$(b64 < "${REGISTRIES_CONF}")"
  [[ -n "${VERITAS_OC_WRAPPER}" ]] && b64_oc_wrapper="$(b64 < "${VERITAS_OC_WRAPPER}")"
  cat > "${node_script}" <<EOF
set -euo pipefail
t=\$(mktemp -d)
trap 'rm -rf "\${t}"' EXIT
mkdir -p "\${t}/out"
printf '%s' '${b64_ps}' | base64 -d > "\${t}/pull-secret.json"
printf '%s' '${b64_id}' | base64 -d > "\${t}/initdata.toml"
podman_args=(run --rm --privileged -v /dev:/dev -v "\${t}:/work:z" -v "\${t}/pull-secret.json:/pull-secret.json:ro,z" -v "\${t}/initdata.toml:/initdata.toml:ro,z")
if [[ -n '${b64_registries}' ]]; then
  # mount ONLY registries.conf — bind-mounting a dir over /etc/containers would hide the
  # image's policy.json + registries.d/ that veritas's inner image pulls rely on
  printf '%s' '${b64_registries}' | base64 -d > "\${t}/registries.conf"
  podman_args+=(-v "\${t}/registries.conf:/etc/containers/registries.conf:ro,z")
fi
if [[ -n '${REGISTRY_CERTS_DIR}' ]]; then
  [[ -d '${REGISTRY_CERTS_DIR}' ]] || { echo "ERROR: REGISTRY_CERTS_DIR not found on node: ${REGISTRY_CERTS_DIR}" >&2; exit 1; }
  podman_args+=(-v '${REGISTRY_CERTS_DIR}:/etc/containers/certs.d:ro,z')
fi
if [[ -n '${b64_oc_wrapper}' ]]; then
  mkdir -p "\${t}/bin"
  printf '%s' '${b64_oc_wrapper}' | base64 -d > "\${t}/bin/oc"
  chmod +x "\${t}/bin/oc"
  podman_args+=(-v "\${t}/bin:/veritas-bin:ro,z" -e PATH="/veritas-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
fi
veritas_args=(veritas --platform baremetal --tee '${TEE}' --authfile /pull-secret.json --initdata /initdata.toml)
for version in ${OCP_VERSION}; do
  veritas_args+=(--ocp-version "\${version}")
done
if [[ -n '${VERITAS_EXTRA_ARGS}' ]]; then
  read -r -a extra_args <<< '${VERITAS_EXTRA_ARGS}'
  veritas_args+=("\${extra_args[@]}")
fi
podman "\${podman_args[@]}" '${TOOLS_IMG}' "\${veritas_args[@]}" -o /work/out >&2
printf '__VERITAS_RVPS_B64_BEGIN__\n'
base64 -w0 "\${t}/out/rvps-reference-values.yaml"
printf '\n__VERITAS_RVPS_B64_END__\n'
EOF
  node_script_b64="$(b64 < "${node_script}")"
  debug_args=(debug "node/${NODE}")
  [[ -n "${DEBUG_IMAGE}" ]] && debug_args+=(--image="${DEBUG_IMAGE}")
  debug_args+=(-- chroot /host bash -c "printf '%s' '${node_script_b64}' | base64 -d > /tmp/gen-rvps-veritas-node.sh && bash /tmp/gen-rvps-veritas-node.sh")
  if ! oc "${debug_args[@]}" > "${capture}" 2>&1; then
    cat "${capture}" >&2
    die "veritas failed on node ${NODE}"
  fi
  if ! awk '/^__VERITAS_RVPS_B64_BEGIN__$/ { emit = 1; next } /^__VERITAS_RVPS_B64_END__$/ { emit = 0 } emit { print }' "${capture}" | b64d > "${OUT}"; then
    cat "${capture}" >&2
    die "could not extract veritas output from oc debug stream"
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
  copy_veritas_output "${veritas_out_dir}" "${OUT}"
fi

[[ -s "${OUT}" ]] || die "veritas produced no output at ${OUT}"
echo "Wrote ${OUT}."
echo "Next: merge into the rvps-reference-values ConfigMap (one run per distinct socket/hardware"
echo "  config; re-run if initdata changes or KBS logs a measurement mismatch)."
[[ "${TEE}" == "tdx" ]] && echo "TDX: derive --hw-xfam-allow flags from Trustee logs (xfam is CPU/BIOS-specific) — do not copy from docs."
exit 0
