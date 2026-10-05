#!/usr/bin/env bash
# Offline CPU-policy extension: preserves vendor appraisals, emits no resource policy.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  cat <<'EOF'
usage: BASE_CPU_POLICY_FILE=<actual-default_cpu.rego> render-measurement-policy.sh <rendered-initdata.toml>

Outputs one Trustee 1.2 CPU ConfigMap in JSON (valid YAML).
CPU_CONFIGMAP_NAME must identify the generated KbsConfig CPU-policy reference.
The input policy must be the reviewed, installed Restricted CPU policy. Its
hardware, launch and configuration appraisals are preserved. This renderer adds
an initdata digest condition; it does not establish what the selected PodVM measures.

Prerequisite: a reviewed default-deny resource policy must enforce affirming
hardware, executables and configuration appraisals. No resource policy is generated.
Run paired allow/tamper/recovery hardware proofs before relying on this binding.
EOF
  exit 0
fi
[[ "$#" == 1 && -s "$1" ]] || { echo 'ERROR: provide exactly one rendered initdata TOML file' >&2; exit 2; }
[[ -s "${BASE_CPU_POLICY_FILE:-}" ]] || { echo 'ERROR: BASE_CPU_POLICY_FILE must be the actual reviewed CPU policy' >&2; exit 2; }
[[ -n "${CPU_CONFIGMAP_NAME:-}" ]] || { echo 'ERROR: CPU_CONFIGMAP_NAME must be resolved from KbsConfig.spec.kbsAttestationPolicyConfigMapName' >&2; exit 2; }
python3 - "$REPO_ROOT/scripts/lib" "$BASE_CPU_POLICY_FILE" "$1" "$CPU_CONFIGMAP_NAME" "${NS:-trustee-operator-system}" "${TEE:-snp}" <<'PY'
import hashlib, json, pathlib, re, sys, tomllib
sys.path.insert(0, sys.argv[1])
from proof_core import Incomplete, bind_initdata_policy
from trustee_config import name, restricted_cpu_features
try:
    raw = pathlib.Path(sys.argv[3]).read_bytes()
    text = raw.decode()
    if re.search(r'__[A-Z][A-Z0-9_]*__', text):
        raise ValueError("initdata contains unresolved placeholders")
    if tomllib.loads(text).get("algorithm") != "sha256":
        raise ValueError("initdata must declare algorithm = sha256")
    base = pathlib.Path(sys.argv[2]).read_text()
    if sys.argv[6] != "snp":
        raise ValueError("this workflow targets AMD SEV-SNP; set TEE=snp")
    restricted_cpu_features(base, sys.argv[6])
    cpu = bind_initdata_policy(base, hashlib.sha256(raw).hexdigest())
    result = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name(sys.argv[4]), "namespace": name(sys.argv[5])}, "data": {"default_cpu.rego": cpu}}
    json.dump(result, sys.stdout, indent=2)
    print()
    print("CPU extension rendered; approved resource policy and paired hardware proof are prerequisites.", file=sys.stderr)
except (ValueError, OSError, Incomplete) as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
