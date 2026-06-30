#!/usr/bin/env bash
# Validate a rung-b direct-pull diagnostic bundle without contacting the cluster.
set -euo pipefail

DIAG_DIR="${1:-${DIAG_DIR:-}}"
REQUIRE_MIRROR_SUMMARY="${REQUIRE_MIRROR_SUMMARY:-1}"

HOST_PULL_BLOCKER_RE='should be decrypted|destination specifies a digest|missing private key needed for decryption|private key needed for decryption'
failures=0

die() {
	echo "ERROR: $*" >&2
	exit 2
}

pass() {
	printf 'PASS: %s\n' "$*"
}

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

usage() {
	cat <<EOF
Usage: validate-rung-b-direct-pull-diagnostic.sh <diagnostic-dir>

Validates a rung-b direct encrypted-image pull diagnostic bundle without contacting
the cluster. The bundle is expected to come from diagnose-rung-b-direct-pull.sh.

Key env:
  DIAG_DIR                 diagnostic directory when not passed as an argument
  REQUIRE_MIRROR_SUMMARY   set 0 to accept older bundles without current mirror/log-window metadata

Exit codes:
  0  diagnostic bundle proves the known host-side blocker shape
  1  diagnostic bundle is present but does not validate
  2  local setup/usage error
EOF
}

require_file() {
	local path="$1" label="$2"
	if [[ -s "$path" ]]; then
		pass "$label present"
	else
		fail "$label missing or empty: $path"
	fi
}

require_file_may_be_empty() {
	local path="$1" label="$2"
	if [[ -f "$path" ]]; then
		pass "$label present"
	else
		fail "$label missing: $path"
	fi
}

summary_value() {
	local key="$1" file="${DIAG_DIR}/summary.env"
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

tsv_value() {
	local file="$1" key="$2"
	awk -F '\t' -v key="$key" 'NR > 1 && $1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "$file"
}

is_digest_ref() {
	[[ "$1" =~ @sha256:[0-9a-f]{64}$ ]]
}

is_nonnegative_int() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

check_expected_value() {
	local key="$1" expected="$2" label="$3" actual
	actual="$(summary_value "$key" 2>/dev/null || true)"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label is $expected"
	else
		fail "$label is ${actual:-missing}, expected $expected"
	fi
}

check_summary_count_matches() {
	local key="$1" expected="$2" label="$3" actual
	actual="$(summary_value "$key" 2>/dev/null || true)"
	if [[ ! "$actual" =~ ^[0-9]+$ ]]; then
		fail "summary.env missing numeric $key"
	elif [[ "$actual" == "$expected" ]]; then
		pass "summary.env $key matches mirror summary ($expected)"
	else
		fail "summary.env $key is $actual, expected $expected from mirror summary for $label"
	fi
}

check_summary() {
	local phase image key_id key_resource mirror_since crio_since
	require_file "${DIAG_DIR}/summary.env" "diagnostic summary"
	if [[ ! -s "${DIAG_DIR}/summary.env" ]]; then
		return
	fi

	check_expected_value classification known-host-pull-blocker "classification"
	check_expected_value host_pull_blocker_seen 1 "host pull blocker signal"
	check_expected_value image_key_request_seen 0 "Trustee image-key request signal"

	phase="$(summary_value_or_default phase "")"
	if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
		fail "diagnostic pod phase is $phase, expected not Running/Succeeded"
	elif [[ -n "$phase" ]]; then
		pass "diagnostic pod did not run: phase=$phase"
	else
		fail "diagnostic pod phase missing"
	fi

	image="$(summary_value_or_default rung_b_image "")"
	if is_digest_ref "$image"; then
		pass "rung-b image is digest-pinned"
	else
		fail "rung-b image is not digest-pinned: ${image:-missing}"
	fi

	key_id="$(summary_value_or_default rung_b_key_id "")"
	key_resource="$(summary_value_or_default rung_b_key_resource "")"
	if [[ "$key_id" == kbs:///* && -n "$key_resource" ]]; then
		pass "rung-b key resource recorded"
	else
		fail "rung-b key ID/resource missing or invalid"
	fi

	mirror_since="$(summary_value_or_default mirror_log_since_time "")"
	if [[ "$REQUIRE_MIRROR_SUMMARY" != "1" ]]; then
		pass "mirror log since-time not required for legacy diagnostic validation"
	elif [[ "$mirror_since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
		pass "mirror logs are bounded by since-time=$mirror_since"
	else
		fail "mirror_log_since_time is ${mirror_since:-missing}; collect bounded mirror logs for current diagnostic bundles"
	fi

	crio_since="$(summary_value_or_default crio_log_since_time "")"
	if [[ "$REQUIRE_MIRROR_SUMMARY" != "1" ]]; then
		pass "CRI-O log since-time not required for legacy diagnostic validation"
	elif [[ "$crio_since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
		pass "CRI-O logs are bounded by since-time=$crio_since"
	else
		fail "crio_log_since_time is ${crio_since:-missing}; collect bounded CRI-O logs for current diagnostic bundles"
	fi
}

check_context() {
	local key_resource
	require_file "${DIAG_DIR}/classification.txt" "classification text"
	if [[ -s "${DIAG_DIR}/classification.txt" ]]; then
		if grep -Fq "REPRODUCED: host-side encrypted-layer pull blocked before guest image-key request." "${DIAG_DIR}/classification.txt"; then
			pass "classification text matches known blocker"
		else
			fail "classification text does not match known blocker"
		fi
	fi

	require_file "${DIAG_DIR}/context.txt" "diagnostic context"
	if [[ -s "${DIAG_DIR}/context.txt" ]]; then
		if grep -Eiq "$HOST_PULL_BLOCKER_RE" "${DIAG_DIR}/context.txt"; then
			pass "context includes host-side encrypted-layer blocker"
		else
			fail "context missing host-side encrypted-layer blocker"
		fi
	fi

	require_file_may_be_empty "${DIAG_DIR}/trustee.log" "Trustee log"
	key_resource="$(summary_value_or_default rung_b_key_resource "")"
	if [[ -n "$key_resource" && -f "${DIAG_DIR}/trustee.log" && -f "${DIAG_DIR}/context.txt" ]]; then
		if grep -Fq "resource/${key_resource}" "${DIAG_DIR}/trustee.log" "${DIAG_DIR}/context.txt" 2>/dev/null; then
			fail "Trustee/context logs include unexpected image-key request: resource/${key_resource}"
		else
			pass "Trustee/context logs do not include image-key request"
		fi
	fi
}

check_crio_log() {
	local crio_log="${DIAG_DIR}/crio-node.log" image
	if [[ "$REQUIRE_MIRROR_SUMMARY" != "1" ]]; then
		pass "CRI-O node log not required for legacy diagnostic validation"
		return
	fi

	require_file "$crio_log" "CRI-O node log"
	[[ -s "$crio_log" ]] || return

	image="$(summary_value_or_default rung_b_image "")"
	if [[ -z "$image" ]]; then
		fail "cannot validate CRI-O host pull without rung_b_image in summary.env"
	elif grep -Fq "Pulling image: $image" "$crio_log" ||
		grep -Fq "Trying to access \"$image\"" "$crio_log"; then
		pass "CRI-O node log includes host pull for rung-b digest"
	else
		fail "CRI-O node log missing host pull for rung-b digest: $image"
	fi

	if [[ -n "$image" ]] && grep -F "image_guest_pull" "$crio_log" | grep -Fq "$image"; then
		fail "CRI-O node log includes unexpected guest-pull source for rung-b digest: $image"
	else
		pass "CRI-O node log does not include rung-b digest as guest-pull source"
	fi
}

check_mirror_summary() {
	local summary="${DIAG_DIR}/mirror/summary.tsv"
	local context_available crio_manifest crio_blob guest_manifest guest_blob
	if [[ ! -s "$summary" ]]; then
		if [[ "$REQUIRE_MIRROR_SUMMARY" == "1" ]]; then
			fail "mirror summary missing or empty: $summary"
		else
			pass "mirror summary not required"
		fi
		return
	fi
	pass "mirror summary present"

	context_available="$(tsv_value "$summary" mirror_context_available 2>/dev/null || true)"
	crio_manifest="$(tsv_value "$summary" crio_rung_b_manifest 2>/dev/null || true)"
	crio_blob="$(tsv_value "$summary" crio_rung_b_blob 2>/dev/null || true)"
	guest_manifest="$(tsv_value "$summary" guest_rung_b_manifest 2>/dev/null || true)"
	guest_blob="$(tsv_value "$summary" guest_rung_b_blob 2>/dev/null || true)"

	if [[ "$context_available" == "1" ]]; then
		pass "mirror context available"
	else
		fail "mirror context unavailable"
	fi

	if is_nonnegative_int "$crio_manifest" && (( crio_manifest > 0 )); then
		pass "mirror summary shows CRI-O rung-b manifest pulls"
	else
		fail "mirror summary missing CRI-O rung-b manifest pulls"
	fi
	if is_nonnegative_int "$crio_blob" && (( crio_blob > 0 )); then
		pass "mirror summary shows CRI-O rung-b blob pulls"
	else
		fail "mirror summary missing CRI-O rung-b blob pulls"
	fi
	if [[ "$guest_manifest" == "0" ]]; then
		pass "mirror summary shows no guest rung-b manifest pulls"
	else
		fail "mirror summary guest rung-b manifest count is ${guest_manifest:-missing}, expected 0"
	fi
	if [[ "$guest_blob" == "0" ]]; then
		pass "mirror summary shows no guest rung-b blob pulls"
	else
		fail "mirror summary guest rung-b blob count is ${guest_blob:-missing}, expected 0"
	fi

	check_summary_count_matches mirror_crio_rung_b_manifest_count "$crio_manifest" "CRI-O manifest pulls"
	check_summary_count_matches mirror_crio_rung_b_blob_count "$crio_blob" "CRI-O blob pulls"
	check_summary_count_matches mirror_guest_rung_b_manifest_count "$guest_manifest" "guest manifest pulls"
	check_summary_count_matches mirror_guest_rung_b_blob_count "$guest_blob" "guest blob pulls"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

[[ -n "$DIAG_DIR" ]] || die "usage: $0 <rung-b-direct-pull-diagnostic-dir> (or set DIAG_DIR)"
[[ -d "$DIAG_DIR" ]] || die "diagnostic directory does not exist: $DIAG_DIR"

check_summary
check_context
check_crio_log
check_mirror_summary

if (( failures > 0 )); then
	echo "Rung-b direct-pull diagnostic validation FAILED (${failures} issue(s))." >&2
	exit 1
fi

echo "Rung-b direct-pull diagnostic validation OK."
