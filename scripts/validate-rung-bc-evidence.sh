#!/usr/bin/env bash
# Validate a collected rung-b/c evidence bundle without contacting the cluster.
set -euo pipefail

EVIDENCE_DIR="${1:-${EVIDENCE_DIR:-}}"
DEFAULT_RUNG_B_POD="rung-b-encrypted"
DEFAULT_RUNG_C_POD="rung-c-signed"
DEFAULT_NEG_RUNG_B_POD="negtest-rung-b"
DEFAULT_NEG_RUNG_C_POD="negtest-rung-c"
DEFAULT_RUNG_B_KEY_ID="kbs:///default/image-key/rung-b"
DEFAULT_RUNG_B_POLICY_URI="kbs:///default/security-policy/test"
DEFAULT_RUNG_C_POLICY_URI="kbs:///default/security-policy/rung-c"
RUNG_B_POD="${RUNG_B_POD:-}"
RUNG_C_POD="${RUNG_C_POD:-}"
NEG_RUNG_B_POD="${NEG_RUNG_B_POD:-}"
NEG_RUNG_C_POD="${NEG_RUNG_C_POD:-}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-}"
DEFAULT_RUNG_B_APP_LOG_MARKER="rung-b: encrypted image decrypted and running"
DEFAULT_RUNG_C_APP_LOG_MARKER="rung-c: signed image accepted and running"
RUNG_B_POLICY_URI="${RUNG_B_POLICY_URI:-}"
RUNG_C_POLICY_URI="${RUNG_C_POLICY_URI:-}"
RUNG_B_TAMPER_MARKER="${RUNG_B_TAMPER_MARKER:-# negative-test tamper: changes SNP HOST_DATA; do not regenerate RVPS}"
KBS_URL="${KBS_URL:-}"
RUNG_B_APP_LOG_MARKER="${RUNG_B_APP_LOG_MARKER:-}"
RUNG_C_APP_LOG_MARKER="${RUNG_C_APP_LOG_MARKER:-}"
RUNG_B_DENIAL_RE="${RUNG_B_DENIAL_RE:-attest|denied|forbidden|measurement|decrypt|image-key|key}"
RUNG_C_DENIAL_RE="${RUNG_C_DENIAL_RE:-policy|sign|signature|sigstore|reject}"

failures=0

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

pass() {
	printf 'PASS: %s\n' "$*"
}

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

require_file() {
	local path="$1" label="$2"
	if [[ -s "$path" ]]; then
		pass "$label present"
	else
		fail "$label missing or empty: $path"
	fi
}

is_digest_ref() {
	[[ "$1" =~ @sha256:[0-9a-f]{64}$ ]]
}

image_repo_path() {
	local image="$1" without_digest last_segment
	without_digest="${image%@*}"
	last_segment="${without_digest##*/}"
	if [[ "$last_segment" == *:* ]]; then
		without_digest="${without_digest%:*}"
	fi
	if [[ "$without_digest" == */* ]]; then
		printf '%s\n' "${without_digest#*/}"
	else
		printf '%s\n' "$without_digest"
	fi
}

image_digest() {
	local image="$1"
	if [[ "$image" =~ @(sha256:[0-9a-f]{64})$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
}

kbs_uri_resource_path() {
	local uri="$1" path
	if [[ "$uri" != kbs:///* ]]; then
		return 1
	fi
	path="${uri#kbs:///}"
	[[ -n "$path" && "$path" != /* ]] || return 1
	printf '%s\n' "$path"
}

kbs_uri_default_secret_key() {
	local uri="$1" path repo secret key extra
	[[ "$uri" == kbs:///* ]] || return 1
	path="${uri#kbs:///}"
	IFS=/ read -r repo secret key extra <<<"$path"
	[[ "$repo" == "default" && -n "$secret" && -n "$key" && -z "${extra:-}" ]] || return 1
	printf '%s\t%s\n' "$secret" "$key"
}

summary_value() {
	local key="$1" file="${EVIDENCE_DIR}/summary.env"
	awk -F '=' -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1; exit } END { if (!found) exit 1 }' "$file"
}

summary_value_or_default() {
	local key="$1" fallback="$2" value
	value="$(summary_value "$key" 2>/dev/null || true)"
	if [[ -n "$value" ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$fallback"
	fi
}

pod_row() {
	local pod="$1" file="${EVIDENCE_DIR}/pods/summary.tsv"
	awk -F '\t' -v pod="$pod" 'NR > 1 && $1 == pod { print; found = 1; exit } END { if (!found) exit 1 }' "$file"
}

pod_col() {
	local pod="$1" col="$2" row
	row="$(pod_row "$pod" 2>/dev/null || true)"
	if [[ -z "$row" ]]; then
		return 1
	fi
	awk -F '\t' -v col="$col" '{ print $col }' <<<"$row"
}

check_manifest() {
	local manifest="${EVIDENCE_DIR}/rung-bc-images.json"
	require_file "$manifest" "rung-bc image manifest"
	if [[ ! -s "$manifest" ]]; then
		return
	fi
	if jq -e --arg rung_b_key_id "$RUNG_B_KEY_ID" '
		def digest_ref: type == "string" and test("@sha256:[0-9a-f]{64}$");
		(.rung_b.digest_ref | digest_ref) and
		(.rung_b.key_id == $rung_b_key_id) and
		(.rung_c.digest_ref | digest_ref) and
		(.rung_c.unsigned_digest_ref | digest_ref) and
		(.rung_b.key_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
		(.rung_c.cosign_pub_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
	' "$manifest" >/dev/null; then
		pass "rung-bc image manifest has digest refs, expected key ID, and artifact fingerprints"
	else
		fail "rung-bc image manifest is missing digest refs/fingerprints or has the wrong rung-b key ID: expected $RUNG_B_KEY_ID"
	fi
}

check_proof_summary() {
	local proof="${EVIDENCE_DIR}/rung-bc-proof-summary.tsv" bad_rows required row missing_rows=0
	require_file "$proof" "rung-bc proof summary"
	if [[ ! -s "$proof" ]]; then
		return
	fi
	for required in \
		rung_b_key_secret_sha256 \
		rung_c_pub_secret_sha256 \
		rung_b_happy_image \
		rung_b_negative_image \
		rung_c_happy_image \
		rung_c_negative_unsigned_image; do
		row="$(awk -F '\t' -v check="$required" 'NR > 1 && $1 == check { print; found = 1; exit } END { if (!found) exit 1 }' "$proof" || true)"
		if [[ -z "$row" ]]; then
			fail "rung-bc proof summary missing required row: $required"
			missing_rows=1
		fi
	done
	bad_rows="$(awk -F '\t' 'NR > 1 && $4 != "match" { print }' "$proof")"
	if [[ -z "$bad_rows" && "$missing_rows" == "0" ]]; then
		pass "rung-bc proof summary rows all match"
	else
		if [[ -n "$bad_rows" ]]; then
			fail "rung-bc proof summary has non-match rows:"
			printf '%s\n' "$bad_rows" >&2
		fi
	fi
}

check_secret_fingerprint() {
	local secret="$1" key="$2" label="$3" expected_bytes="${4:-}"
	local file="${EVIDENCE_DIR}/trustee/secrets/rung-bc-fingerprints.tsv"
	local row status bytes sha
	require_file "$file" "rung-bc secret fingerprint table"
	if [[ ! -s "$file" ]]; then
		return
	fi
	row="$(awk -F '\t' -v secret="$secret" -v key="$key" 'NR > 1 && $1 == secret && $2 == key { print; found = 1; exit } END { if (!found) exit 1 }' "$file" || true)"
	if [[ -z "$row" ]]; then
		fail "$label fingerprint row missing"
		return
	fi
	status="$(awk -F '\t' '{ print $3 }' <<<"$row")"
	bytes="$(awk -F '\t' '{ print $4 }' <<<"$row")"
	sha="$(awk -F '\t' '{ print $5 }' <<<"$row")"
	if [[ "$status" != "present" ]]; then
		fail "$label fingerprint status is $status"
		return
	fi
	if [[ -n "$expected_bytes" && "$bytes" != "$expected_bytes" ]]; then
		fail "$label decoded bytes mismatch: expected $expected_bytes, got $bytes"
	elif [[ ! "$bytes" =~ ^[0-9]+$ || "$bytes" -le 0 ]]; then
		fail "$label decoded bytes are invalid: $bytes"
	elif [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
		pass "$label fingerprint present"
	else
		fail "$label sha256 is invalid: $sha"
	fi
}

check_pod_phase() {
	local pod="$1" label="$2" mode="$3"
	local status phase runtime image
	status="$(pod_col "$pod" 2 2>/dev/null || true)"
	phase="$(pod_col "$pod" 5 2>/dev/null || true)"
	runtime="$(pod_col "$pod" 6 2>/dev/null || true)"
	image="$(pod_col "$pod" 8 2>/dev/null || true)"
	if [[ "$status" != "present" ]]; then
		fail "$label pod is not present in pods/summary.tsv"
		return
	fi
	if [[ "$runtime" != "kata-cc" ]]; then
		fail "$label pod runtime class is $runtime, expected kata-cc"
	else
		pass "$label pod uses kata-cc"
	fi
	if ! is_digest_ref "$image"; then
		fail "$label pod app image is not digest-pinned: $image"
	else
		pass "$label pod app image is digest-pinned"
	fi
	case "$mode" in
		happy)
			if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
				pass "$label happy pod reached $phase"
			else
				fail "$label happy pod phase is $phase, expected Running or Succeeded"
			fi
			;;
		denied)
			if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
				fail "$label denied pod reached $phase"
			else
				pass "$label denied pod did not reach Running/Succeeded"
			fi
			;;
		*) die "unknown pod phase mode: $mode" ;;
	esac
}

check_happy_app_started() {
	local pod="$1" label="$2" marker="$3"
	local logs="${EVIDENCE_DIR}/pods/${pod}.logs.txt"
	local pod_json="${EVIDENCE_DIR}/pods/${pod}.json"
	if [[ -s "$logs" ]] && grep -Fq "$marker" "$logs"; then
		pass "$label app log marker present"
		return
	fi
	require_file "$pod_json" "$label pod JSON"
	if [[ ! -s "$pod_json" ]]; then
		return
	fi
	if jq -e '
		def condition_true($name):
			any(.status.conditions[]?; .type == $name and .status == "True");
		def app_started:
			any(.status.containerStatuses[]?; .name == "app" and (
				(.ready == true and ((.started == true) or (.state.running.startedAt? != null))) or
				(.state.terminated.exitCode? == 0 and (.state.terminated.startedAt? != null))
			));
		(
			(.status.phase == "Running" and (condition_true("Ready") or condition_true("ContainersReady")) and app_started) or
			(.status.phase == "Succeeded" and app_started)
		)
	' "$pod_json" >/dev/null; then
		pass "$label app start proven by pod status"
	else
		fail "$label app start evidence missing: log marker not found and pod JSON does not show app container started"
	fi
}

check_initdata_relationships() {
	local rung_b_initdata neg_rung_b_initdata rung_c_initdata neg_rung_c_initdata
	rung_b_initdata="${EVIDENCE_DIR}/pods/${RUNG_B_POD}.initdata.toml"
	neg_rung_b_initdata="${EVIDENCE_DIR}/pods/${NEG_RUNG_B_POD}.initdata.toml"
	rung_c_initdata="${EVIDENCE_DIR}/pods/${RUNG_C_POD}.initdata.toml"
	neg_rung_c_initdata="${EVIDENCE_DIR}/pods/${NEG_RUNG_C_POD}.initdata.toml"

	if [[ ! -s "$rung_b_initdata" || ! -s "$neg_rung_b_initdata" ]]; then
		fail "rung-b decoded initdata missing for relationship check"
	elif cmp -s "$rung_b_initdata" "$neg_rung_b_initdata"; then
		fail "rung-b negative decoded initdata matches happy decoded initdata"
	else
		pass "rung-b negative decoded initdata differs from happy decoded initdata"
	fi

	if [[ ! -s "$rung_c_initdata" || ! -s "$neg_rung_c_initdata" ]]; then
		fail "rung-c decoded initdata missing for relationship check"
	elif ! cmp -s "$rung_c_initdata" "$neg_rung_c_initdata"; then
		fail "rung-c negative decoded initdata differs from happy decoded initdata"
	else
		pass "rung-c negative decoded initdata matches happy decoded initdata"
	fi
}

check_decoded_initdata() {
	local pod="$1" label="$2" policy_uri="$3" tamper_marker="${4:-}"
	local initdata="${EVIDENCE_DIR}/pods/${pod}.initdata.toml"
	local decode_err="${EVIDENCE_DIR}/pods/${pod}.initdata.decode.err"
	local kbs_url_count
	require_file "$initdata" "$label decoded initdata"
	if [[ ! -s "$initdata" ]]; then
		return
	fi
	if [[ -f "$decode_err" ]]; then
		if [[ -s "$decode_err" ]]; then
			fail "$label initdata decode stderr is not empty: $decode_err"
		else
			pass "$label initdata decoded without stderr"
		fi
	else
		fail "$label initdata decode stderr file missing: $decode_err"
	fi
	if grep -Fq "image_security_policy_uri = \"${policy_uri}\"" "$initdata"; then
		pass "$label initdata policy URI present"
	else
		fail "$label initdata policy URI missing: $policy_uri"
	fi
	if [[ -n "$KBS_URL" ]]; then
		kbs_url_count="$(awk -v needle="url = \"${KBS_URL}\"" 'index($0, needle) { count++ } END { print count + 0 }' "$initdata")"
		if [[ "$kbs_url_count" -ge 2 ]]; then
			pass "$label initdata KBS URL present"
		else
			fail "$label initdata KBS URL missing or incomplete: $KBS_URL"
		fi
	fi
	if [[ -n "$tamper_marker" ]]; then
		if grep -Fq "$tamper_marker" "$initdata"; then
			pass "$label initdata tamper marker present"
		else
			fail "$label initdata tamper marker missing"
		fi
	fi
}

bundle_text_for_pod() {
	local pod="$1" file
	for file in \
		"${EVIDENCE_DIR}/pods/${pod}.describe.txt" \
		"${EVIDENCE_DIR}/pods/${pod}.logs.txt" \
		"${EVIDENCE_DIR}/trustee/logs.txt" \
		"${EVIDENCE_DIR}/trustee/events.txt" \
		"${EVIDENCE_DIR}/cluster/workload-events.txt"; do
		[[ -f "$file" ]] && cat "$file"
		printf '\n'
	done
}

check_denial_signal() {
	local pod="$1" label="$2" pattern="$3" context
	context="$(bundle_text_for_pod "$pod")"
	if grep -qiE "$pattern" <<<"$context"; then
		pass "$label denial signal present"
	else
		fail "$label denial signal missing"
	fi
}

check_kbs_logs() {
	local logs="${EVIDENCE_DIR}/trustee/logs.txt" resource rung_b_resource rung_c_policy_resource
	require_file "$logs" "Trustee logs"
	if [[ ! -s "$logs" ]]; then
		return
	fi
	rung_b_resource="$(kbs_uri_resource_path "$RUNG_B_KEY_ID" || true)"
	if [[ -z "$rung_b_resource" ]]; then
		fail "rung-b key ID is not a kbs:/// resource URI: $RUNG_B_KEY_ID"
		return
	fi
	rung_c_policy_resource="$(kbs_uri_resource_path "$RUNG_C_POLICY_URI" || true)"
	if [[ -z "$rung_c_policy_resource" ]]; then
		fail "rung-c policy URI is not a kbs:/// resource URI: $RUNG_C_POLICY_URI"
		return
	fi
	for resource in "$rung_b_resource" "$rung_c_policy_resource" default/sig-public-key/rung-c; do
		if grep -Fq "resource/${resource}" "$logs"; then
			pass "Trustee logs include resource/${resource}"
		else
			fail "Trustee logs missing resource/${resource}"
		fi
	done
}

mirror_log_context() {
	local file
	for file in \
		"${EVIDENCE_DIR}"/mirror/files/* \
		"${EVIDENCE_DIR}"/mirror/containers/*.log; do
		[[ -f "$file" ]] && cat "$file"
		printf '\n'
	done
}

check_mirror_image_pull() {
	local label="$1" image="$2" context="$3" agent_label="$4" agent_pattern="$5" require_blob="$6"
	local repo digest digest_hex
	if [[ -z "$image" ]]; then
		fail "$label mirror image ref missing from manifest"
		return
	fi
	repo="$(image_repo_path "$image")"
	digest="$(image_digest "$image")"
	if [[ -z "$digest" ]]; then
		fail "$label mirror image ref is not a sha256 digest ref: $image"
		return
	fi
	digest_hex="${digest#sha256:}"
	if awk -v repo="$repo" -v digest="$digest" -v digest_hex="$digest_hex" -v agent="$agent_pattern" '
		index($0, repo) && index($0, "/manifests/") && (index($0, digest) || index($0, digest_hex)) && index($0, agent) {
			found = 1
		}
		END { exit found ? 0 : 1 }
	' <<<"$context"; then
		pass "$label mirror logs include ${agent_label} manifest pull ${repo}@${digest}"
	else
		fail "$label mirror logs missing ${agent_label} manifest pull ${repo}@${digest}"
	fi
	if [[ "$require_blob" != "1" ]]; then
		return
	fi
	if awk -v repo="$repo" -v agent="$agent_pattern" '
		index($0, repo) && index($0, "/blobs/") && index($0, agent) {
			found = 1
		}
		END { exit found ? 0 : 1 }
	' <<<"$context"; then
		pass "$label mirror logs include ${agent_label} blob pull ${repo}"
	else
		fail "$label mirror logs missing ${agent_label} blob pull ${repo}"
	fi
}

check_mirror_logs() {
	local manifest="${EVIDENCE_DIR}/rung-bc-images.json" context
	local rung_b_image rung_c_image rung_c_unsigned_image
	context="$(mirror_log_context)"
	if [[ -z "$(tr -d '[:space:]' <<<"$context")" ]]; then
		fail "mirror logs missing or empty"
		return
	fi
	if [[ ! -s "$manifest" ]]; then
		fail "cannot validate mirror pulls without rung-bc-images.json"
		return
	fi
	rung_b_image="$(jq -r '.rung_b.digest_ref // ""' "$manifest")"
	rung_c_image="$(jq -r '.rung_c.digest_ref // ""' "$manifest")"
	rung_c_unsigned_image="$(jq -r '.rung_c.unsigned_digest_ref // ""' "$manifest")"
	check_mirror_image_pull "rung-b happy image" "$rung_b_image" "$context" "guest oci-client" "oci-client/" 1
	check_mirror_image_pull "rung-c happy image" "$rung_c_image" "$context" "guest oci-client" "oci-client/" 1
	check_mirror_image_pull "rung-c unsigned negative image" "$rung_c_unsigned_image" "$context" "guest oci-client" "oci-client/" 0
}

check_summary() {
	local summary="${EVIDENCE_DIR}/summary.env" dirty trustee_since mirror_since
	require_file "$summary" "evidence summary"
	if [[ ! -s "$summary" ]]; then
		return
	fi
	dirty="$(summary_value repo_git_dirty 2>/dev/null || true)"
	if [[ "$dirty" == "false" ]]; then
		pass "evidence was collected from a clean git worktree"
	else
		fail "evidence repo_git_dirty is ${dirty:-missing}; collect from a clean checkout for promotion evidence"
	fi
	trustee_since="$(summary_value trustee_log_since_time 2>/dev/null || true)"
	if [[ "$trustee_since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
		pass "Trustee logs are bounded by --since-time=$trustee_since"
	else
		fail "evidence trustee_log_since_time is ${trustee_since:-missing}; collect bounded Trustee logs for promotion evidence"
	fi
	mirror_since="$(summary_value mirror_log_since_time 2>/dev/null || true)"
	if [[ "$mirror_since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
		pass "Mirror logs are bounded by since-time=$mirror_since"
	else
		fail "evidence mirror_log_since_time is ${mirror_since:-missing}; collect bounded mirror logs for promotion evidence"
	fi
}

[[ -n "$EVIDENCE_DIR" ]] || die "usage: $0 <evidence-dir> (or set EVIDENCE_DIR)"
[[ -d "$EVIDENCE_DIR" ]] || die "evidence directory does not exist: $EVIDENCE_DIR"
need jq
need awk
need grep
need cmp
RUNG_B_APP_LOG_MARKER="${RUNG_B_APP_LOG_MARKER:-$(summary_value_or_default rung_b_app_log_marker "$DEFAULT_RUNG_B_APP_LOG_MARKER")}"
RUNG_C_APP_LOG_MARKER="${RUNG_C_APP_LOG_MARKER:-$(summary_value_or_default rung_c_app_log_marker "$DEFAULT_RUNG_C_APP_LOG_MARKER")}"
KBS_URL="${KBS_URL:-$(summary_value_or_default kbs_url "")}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-$(summary_value_or_default rung_b_key_id "$DEFAULT_RUNG_B_KEY_ID")}"
RUNG_B_POLICY_URI="${RUNG_B_POLICY_URI:-$(summary_value_or_default rung_b_policy_uri "$DEFAULT_RUNG_B_POLICY_URI")}"
RUNG_C_POLICY_URI="${RUNG_C_POLICY_URI:-$(summary_value_or_default rung_c_policy_uri "$DEFAULT_RUNG_C_POLICY_URI")}"
RUNG_B_POD="${RUNG_B_POD:-$(summary_value_or_default rung_b_pod "$DEFAULT_RUNG_B_POD")}"
RUNG_C_POD="${RUNG_C_POD:-$(summary_value_or_default rung_c_pod "$DEFAULT_RUNG_C_POD")}"
NEG_RUNG_B_POD="${NEG_RUNG_B_POD:-$(summary_value_or_default neg_rung_b_pod "$DEFAULT_NEG_RUNG_B_POD")}"
NEG_RUNG_C_POD="${NEG_RUNG_C_POD:-$(summary_value_or_default neg_rung_c_pod "$DEFAULT_NEG_RUNG_C_POD")}"

check_summary
check_manifest
check_proof_summary
rung_b_key_secret="$(kbs_uri_default_secret_key "$RUNG_B_KEY_ID" || true)"
if [[ -n "$rung_b_key_secret" ]]; then
	check_secret_fingerprint "${rung_b_key_secret%%	*}" "${rung_b_key_secret#*	}" "rung-b image key" 32
else
	fail "rung-b key ID is not a kbs:///default/<secret>/<key> URI: $RUNG_B_KEY_ID"
fi
check_secret_fingerprint sig-public-key rung-c "rung-c public key"
check_secret_fingerprint security-policy rung-c "rung-c security policy"
require_file "${EVIDENCE_DIR}/pods/summary.tsv" "pod summary index"
check_pod_phase "$RUNG_B_POD" "rung-b" happy
check_pod_phase "$RUNG_C_POD" "rung-c" happy
check_happy_app_started "$RUNG_B_POD" "rung-b" "$RUNG_B_APP_LOG_MARKER"
check_happy_app_started "$RUNG_C_POD" "rung-c" "$RUNG_C_APP_LOG_MARKER"
check_pod_phase "$NEG_RUNG_B_POD" "rung-b negative" denied
check_pod_phase "$NEG_RUNG_C_POD" "rung-c negative" denied
check_initdata_relationships
check_decoded_initdata "$RUNG_B_POD" "rung-b" "$RUNG_B_POLICY_URI"
check_decoded_initdata "$RUNG_C_POD" "rung-c" "$RUNG_C_POLICY_URI"
check_decoded_initdata "$NEG_RUNG_B_POD" "rung-b negative" "$RUNG_B_POLICY_URI" "$RUNG_B_TAMPER_MARKER"
check_decoded_initdata "$NEG_RUNG_C_POD" "rung-c negative" "$RUNG_C_POLICY_URI"
check_kbs_logs
check_mirror_logs
check_denial_signal "$NEG_RUNG_B_POD" "rung-b negative" "$RUNG_B_DENIAL_RE"
check_denial_signal "$NEG_RUNG_C_POD" "rung-c negative" "$RUNG_C_DENIAL_RE"

if (( failures > 0 )); then
	echo "Rung b/c evidence validation FAILED (${failures} issue(s))." >&2
	exit 1
fi

echo "Rung b/c evidence validation OK."
