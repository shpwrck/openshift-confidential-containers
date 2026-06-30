#!/usr/bin/env bash
# Run the rung-b/c happy paths, fail-closed proofs, evidence collection, and validation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${ARTIFACT_DIR}/evidence-rung-bc-proof-$(date -u +%Y%m%dT%H%M%SZ)}"
RUNG_B_IMAGE="${RUNG_B_IMAGE:-}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-}"
RUNG_C_UNSIGNED_IMAGE="${RUNG_C_UNSIGNED_IMAGE:-}"
APPLY_RUNG_B_SCRIPT="${APPLY_RUNG_B_SCRIPT:-${REPO_ROOT}/scripts/apply-rung-b.sh}"
APPLY_RUNG_C_SCRIPT="${APPLY_RUNG_C_SCRIPT:-${REPO_ROOT}/scripts/apply-rung-c.sh}"
NEGATIVE_TEST_SCRIPT="${NEGATIVE_TEST_SCRIPT:-${REPO_ROOT}/scripts/negative-test.sh}"
COLLECT_RUNG_BC_EVIDENCE_SCRIPT="${COLLECT_RUNG_BC_EVIDENCE_SCRIPT:-${REPO_ROOT}/scripts/collect-rung-bc-evidence.sh}"
VALIDATE_RUNG_BC_EVIDENCE_SCRIPT="${VALIDATE_RUNG_BC_EVIDENCE_SCRIPT:-${REPO_ROOT}/scripts/validate-rung-bc-evidence.sh}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

require_digest_ref() {
	local var_name="$1" image="$2"
	if [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
		return
	fi
	die "${var_name} must be a sha256 digest ref for proof runs: ${image:-<unset>}. Source ${ARTIFACT_DIR}/rung-bc.env after make build-rung-images."
}

require_script() {
	local path="$1"
	[[ -f "$path" ]] || die "missing script: $path"
}

require_digest_ref RUNG_B_IMAGE "$RUNG_B_IMAGE"
require_digest_ref RUNG_C_IMAGE "$RUNG_C_IMAGE"
require_digest_ref RUNG_C_UNSIGNED_IMAGE "$RUNG_C_UNSIGNED_IMAGE"
require_script "$APPLY_RUNG_B_SCRIPT"
require_script "$APPLY_RUNG_C_SCRIPT"
require_script "$NEGATIVE_TEST_SCRIPT"
require_script "$COLLECT_RUNG_BC_EVIDENCE_SCRIPT"
require_script "$VALIDATE_RUNG_BC_EVIDENCE_SCRIPT"

echo "== rung-b happy path =="
bash "$APPLY_RUNG_B_SCRIPT"

echo
echo "== rung-c happy path =="
bash "$APPLY_RUNG_C_SCRIPT"

echo
echo "== rung-b fail-closed proof =="
KEEP_DENIED_PODS=1 bash "$NEGATIVE_TEST_SCRIPT" rung-b

echo
echo "== rung-c fail-closed proof =="
KEEP_DENIED_PODS=1 bash "$NEGATIVE_TEST_SCRIPT" rung-c

echo
echo "== collect rung-b/c evidence =="
EVIDENCE_DIR="$EVIDENCE_DIR" bash "$COLLECT_RUNG_BC_EVIDENCE_SCRIPT"

echo
echo "== validate rung-b/c evidence =="
bash "$VALIDATE_RUNG_BC_EVIDENCE_SCRIPT" "$EVIDENCE_DIR"

echo
echo "Rung b/c proof workflow complete. Evidence: $EVIDENCE_DIR"
