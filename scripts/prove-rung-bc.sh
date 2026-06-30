#!/usr/bin/env bash
# Run the rung-b/c happy paths, fail-closed proofs, evidence collection, and validation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/rung-bc-artifacts}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${ARTIFACT_DIR}/evidence-rung-bc-proof-$(date -u +%Y%m%dT%H%M%SZ)}"
RUNG_ENV_FILE="${RUNG_ENV_FILE:-${ARTIFACT_DIR}/rung-bc.env}"
RUNG_B_IMAGE="${RUNG_B_IMAGE:-}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-}"
RUNG_C_UNSIGNED_IMAGE="${RUNG_C_UNSIGNED_IMAGE:-}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
KBS_URL="${KBS_URL:-http://kbs-service.${TRUSTEE_NS}.svc:8080}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-kbs:///default/image-key/rung-b}"
RUNG_B_POLICY_URI="${RUNG_B_POLICY_URI:-kbs:///default/security-policy/test}"
RUNG_C_POLICY_URI="${RUNG_C_POLICY_URI:-kbs:///default/security-policy/rung-c}"
PODS="${PODS:-rung-a-secret rung-b-encrypted rung-c-signed negtest-rung-a negtest-rung-b negtest-rung-c negtest-air-gap}"
RUNG_B_POD="${RUNG_B_POD:-rung-b-encrypted}"
RUNG_C_POD="${RUNG_C_POD:-rung-c-signed}"
NEG_RUNG_B_POD="${NEG_RUNG_B_POD:-negtest-rung-b}"
NEG_RUNG_C_POD="${NEG_RUNG_C_POD:-negtest-rung-c}"
RUNG_B_APP_LOG_MARKER="${RUNG_B_APP_LOG_MARKER:-rung-b: encrypted image decrypted and running}"
RUNG_C_APP_LOG_MARKER="${RUNG_C_APP_LOG_MARKER:-rung-c: signed image accepted and running}"
TRUSTEE_LOG_TAIL="${TRUSTEE_LOG_TAIL:-1000}"
TRUSTEE_LOG_SINCE_TIME="${TRUSTEE_LOG_SINCE_TIME:-$PROOF_STARTED_AT_UTC}"
POD_LOG_TAIL="${POD_LOG_TAIL:-200}"
CRIO_LOG_TAIL="${CRIO_LOG_TAIL:-1000}"
CRIO_LOG_SINCE_TIME="${CRIO_LOG_SINCE_TIME:-$PROOF_STARTED_AT_UTC}"
MIRROR_LOG_TAIL="${MIRROR_LOG_TAIL:-1000}"
MIRROR_LOG_SINCE_TIME="${MIRROR_LOG_SINCE_TIME:-$PROOF_STARTED_AT_UTC}"
MIRROR_LOG_FILES="${MIRROR_LOG_FILES:-}"
MIRROR_CONTAINER_NAMES="${MIRROR_CONTAINER_NAMES:-}"
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

all_image_refs_are_digest_pinned() {
	[[ "$RUNG_B_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] &&
		[[ "$RUNG_C_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] &&
		[[ "$RUNG_C_UNSIGNED_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]]
}

load_rung_env_if_needed() {
	if all_image_refs_are_digest_pinned; then
		return
	fi
	if [[ ! -f "$RUNG_ENV_FILE" ]]; then
		return
	fi
	echo "Loading rung b/c digest refs from $RUNG_ENV_FILE"
	# shellcheck source=/dev/null
	source "$RUNG_ENV_FILE"
}

require_script() {
	local path="$1"
	[[ -f "$path" ]] || die "missing script: $path"
}

load_rung_env_if_needed
require_digest_ref RUNG_B_IMAGE "$RUNG_B_IMAGE"
require_digest_ref RUNG_C_IMAGE "$RUNG_C_IMAGE"
require_digest_ref RUNG_C_UNSIGNED_IMAGE "$RUNG_C_UNSIGNED_IMAGE"
require_script "$APPLY_RUNG_B_SCRIPT"
require_script "$APPLY_RUNG_C_SCRIPT"
require_script "$NEGATIVE_TEST_SCRIPT"
require_script "$COLLECT_RUNG_BC_EVIDENCE_SCRIPT"
require_script "$VALIDATE_RUNG_BC_EVIDENCE_SCRIPT"

echo "== rung-b happy path =="
KBS_URL="$KBS_URL" RUNG_B_KEY_ID="$RUNG_B_KEY_ID" IMAGE_SECURITY_POLICY_URI="$RUNG_B_POLICY_URI" RUNG_B_IMAGE="$RUNG_B_IMAGE" bash "$APPLY_RUNG_B_SCRIPT"

echo
echo "== rung-c happy path =="
KBS_URL="$KBS_URL" IMAGE_SECURITY_POLICY_URI="$RUNG_C_POLICY_URI" RUNG_C_IMAGE="$RUNG_C_IMAGE" bash "$APPLY_RUNG_C_SCRIPT"

echo
echo "== rung-b fail-closed proof =="
KBS_URL="$KBS_URL" RUNG_B_POLICY_URI="$RUNG_B_POLICY_URI" RUNG_B_IMAGE="$RUNG_B_IMAGE" KEEP_DENIED_PODS=1 bash "$NEGATIVE_TEST_SCRIPT" rung-b

echo
echo "== rung-c fail-closed proof =="
KBS_URL="$KBS_URL" RUNG_C_POLICY_URI="$RUNG_C_POLICY_URI" RUNG_C_UNSIGNED_IMAGE="$RUNG_C_UNSIGNED_IMAGE" KEEP_DENIED_PODS=1 bash "$NEGATIVE_TEST_SCRIPT" rung-c

echo
echo "== collect rung-b/c evidence =="
EVIDENCE_DIR="$EVIDENCE_DIR" KBS_URL="$KBS_URL" RUNG_B_KEY_ID="$RUNG_B_KEY_ID" RUNG_B_POLICY_URI="$RUNG_B_POLICY_URI" RUNG_C_POLICY_URI="$RUNG_C_POLICY_URI" PODS="$PODS" RUNG_B_POD="$RUNG_B_POD" \
	RUNG_C_POD="$RUNG_C_POD" NEG_RUNG_B_POD="$NEG_RUNG_B_POD" NEG_RUNG_C_POD="$NEG_RUNG_C_POD" \
	RUNG_B_APP_LOG_MARKER="$RUNG_B_APP_LOG_MARKER" RUNG_C_APP_LOG_MARKER="$RUNG_C_APP_LOG_MARKER" \
	TRUSTEE_LOG_TAIL="$TRUSTEE_LOG_TAIL" TRUSTEE_LOG_SINCE_TIME="$TRUSTEE_LOG_SINCE_TIME" POD_LOG_TAIL="$POD_LOG_TAIL" CRIO_LOG_TAIL="$CRIO_LOG_TAIL" CRIO_LOG_SINCE_TIME="$CRIO_LOG_SINCE_TIME" MIRROR_LOG_TAIL="$MIRROR_LOG_TAIL" MIRROR_LOG_SINCE_TIME="$MIRROR_LOG_SINCE_TIME" \
	MIRROR_LOG_FILES="$MIRROR_LOG_FILES" MIRROR_CONTAINER_NAMES="$MIRROR_CONTAINER_NAMES" \
	bash "$COLLECT_RUNG_BC_EVIDENCE_SCRIPT"

echo
echo "== validate rung-b/c evidence =="
KBS_URL="$KBS_URL" RUNG_B_KEY_ID="$RUNG_B_KEY_ID" RUNG_B_POLICY_URI="$RUNG_B_POLICY_URI" RUNG_C_POLICY_URI="$RUNG_C_POLICY_URI" RUNG_B_POD="$RUNG_B_POD" RUNG_C_POD="$RUNG_C_POD" \
	NEG_RUNG_B_POD="$NEG_RUNG_B_POD" NEG_RUNG_C_POD="$NEG_RUNG_C_POD" \
	RUNG_B_APP_LOG_MARKER="$RUNG_B_APP_LOG_MARKER" RUNG_C_APP_LOG_MARKER="$RUNG_C_APP_LOG_MARKER" \
	bash "$VALIDATE_RUNG_BC_EVIDENCE_SCRIPT" "$EVIDENCE_DIR"

echo
echo "Rung b/c proof workflow complete. Evidence: $EVIDENCE_DIR"
