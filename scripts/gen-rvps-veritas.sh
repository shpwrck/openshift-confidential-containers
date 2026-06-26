#!/usr/bin/env bash
# Generate RVPS reference values with Veritas. Hardware-bound: run on the TARGET hardware
# (rig proves the procedure; customer metal regenerates the data). One run per distinct
# hardware config (CPU family + firmware). See docs/notes/enterprise-onboarding-guide.md Step 5.
#
# Runs the coco-tools `veritas` generator over your initdata and emits an RVPS reference-values
# YAML to merge into the `rvps-reference-values` ConfigMap (gitops/base/trustee/kbsconfig.yaml).
#
# Where it runs: by default `podman` on THIS host (point it at the node, or copy initdata to the
# node and run there). Set NODE=<name> to run it on the cluster node via `oc debug node` instead
# — use that if veritas needs to read the live firmware/TCB rather than just the initdata.
#
# Usage:    TEE=snp ./scripts/gen-rvps-veritas.sh            # local podman
#           TEE=snp NODE=<node> ./scripts/gen-rvps-veritas.sh # run on the node via oc debug
# Env: TEE=snp|tdx  PULL_SECRET=./pull-secret.json  INITDATA=./initdata-flavour-b.toml  OUT=./rvps-<tee>.yaml
set -euo pipefail

TEE="${TEE:-snp}"
TOOLS_IMG="${TOOLS_IMG:-quay.io/openshift_sandboxed_containers/coco-tools:1.12}"
PULL_SECRET="${PULL_SECRET:-./pull-secret.json}"
INITDATA="${INITDATA:-./initdata-flavour-b.toml}"
OUT="${OUT:-./rvps-${TEE}.yaml}"
NODE="${NODE:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "${TEE}" == "snp" || "${TEE}" == "tdx" ]] || die "TEE must be 'snp' or 'tdx' (got '${TEE}')"
[[ -s "${INITDATA}" ]] || die "initdata not found: ${INITDATA} (set INITDATA=...)"

# shared veritas flags; the -o path differs per run mode (mounted output dir)
VFLAGS="veritas --platform baremetal --tee ${TEE} --authfile /pull-secret.json --initdata /initdata.toml"

if [[ -n "${NODE}" ]]; then
  # Run on the node: stage inputs into the debug pod, run podman there, stream the YAML back.
  command -v oc >/dev/null || die "oc not on PATH (needed for NODE mode)"
  oc whoami >/dev/null 2>&1 || die "not logged into a cluster"
  [[ -s "${PULL_SECRET}" ]] || die "pull secret not found: ${PULL_SECRET}"
  echo ">> running veritas (${TEE}) on node ${NODE}"
  b64_ps="$(base64 -w0 "${PULL_SECRET}")"; b64_id="$(base64 -w0 "${INITDATA}")"
  oc debug "node/${NODE}" -- chroot /host bash -c "
    set -e; t=\$(mktemp -d)
    echo '${b64_ps}' | base64 -d > \$t/pull-secret.json
    echo '${b64_id}' | base64 -d > \$t/initdata.toml
    podman run --rm --privileged -v /dev:/dev \
      -v \$t:/work:z \
      -v \$t/pull-secret.json:/pull-secret.json:ro,z -v \$t/initdata.toml:/initdata.toml:ro,z \
      ${TOOLS_IMG} ${VFLAGS} -o /work/out.yaml >&2
    cat \$t/out.yaml; rm -rf \$t
  " > "${OUT}"
else
  command -v podman >/dev/null || die "podman not on PATH (or set NODE=<node> to run on the cluster node)"
  [[ -s "${PULL_SECRET}" ]] || die "pull secret not found: ${PULL_SECRET} (set PULL_SECRET=...)"
  echo ">> running veritas (${TEE}) locally via podman"
  outdir="$(cd "$(dirname "${OUT}")" && pwd)"
  podman run --rm --privileged \
    -v "${PULL_SECRET}":/pull-secret.json:ro,z \
    -v "${INITDATA}":/initdata.toml:ro,z \
    -v "${outdir}":/outdir:z \
    "${TOOLS_IMG}" ${VFLAGS} -o "/outdir/$(basename "${OUT}")"
fi

[[ -s "${OUT}" ]] || die "veritas produced no output at ${OUT}"
echo "Wrote ${OUT}."
echo "Next: merge into the rvps-reference-values ConfigMap (one run per distinct socket/hardware"
echo "  config; re-run if initdata changes or KBS logs a measurement mismatch)."
[[ "${TEE}" == "tdx" ]] && echo "TDX: derive --hw-xfam-allow flags from Trustee logs (xfam is CPU/BIOS-specific) — do not copy from docs."
exit 0
