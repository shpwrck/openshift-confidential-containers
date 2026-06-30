#!/usr/bin/env bash
# Print an issue-ready summary for a rung-b direct-pull diagnostic bundle.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAG_DIR="${1:-${DIAG_DIR:-}}"
REQUIRE_MIRROR_SUMMARY="${REQUIRE_MIRROR_SUMMARY:-1}"
VALIDATE_DIAGNOSTIC="${VALIDATE_DIAGNOSTIC:-1}"
VALIDATE_RUNG_B_DIRECT_PULL_DIAG_SCRIPT="${VALIDATE_RUNG_B_DIRECT_PULL_DIAG_SCRIPT:-${REPO_ROOT}/scripts/validate-rung-b-direct-pull-diagnostic.sh}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

usage() {
	cat <<EOF
Usage: summarize-rung-b-direct-pull-diagnostic.sh <diagnostic-dir>

Validates a rung-b direct encrypted-image pull diagnostic bundle, then prints a
compact Markdown summary suitable for PR or upstream issue comments.

Key env:
  DIAG_DIR                 diagnostic directory when not passed as an argument
  REQUIRE_MIRROR_SUMMARY   forwarded to the validator (default: 1)
  VALIDATE_DIAGNOSTIC      set 0 to skip validation before summary output
  VALIDATE_RUNG_B_DIRECT_PULL_DIAG_SCRIPT
                           validator script path

Exit codes:
  0  summary written
  1  validator rejected the bundle
  2  local setup/usage error
EOF
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

tsv_value_or_default() {
	local file="$1" key="$2" fallback="$3" value
	value="$(awk -F '\t' -v key="$key" 'NR > 1 && $1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "$file" 2>/dev/null || true)"
	if [[ -n "$value" ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$fallback"
	fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

[[ -n "$DIAG_DIR" ]] || die "usage: $0 <rung-b-direct-pull-diagnostic-dir> (or set DIAG_DIR)"
[[ -d "$DIAG_DIR" ]] || die "diagnostic directory does not exist: $DIAG_DIR"
[[ -s "${DIAG_DIR}/summary.env" ]] || die "diagnostic summary missing or empty: ${DIAG_DIR}/summary.env"

if [[ "$VALIDATE_DIAGNOSTIC" == "1" ]]; then
	REQUIRE_MIRROR_SUMMARY="$REQUIRE_MIRROR_SUMMARY" bash "$VALIDATE_RUNG_B_DIRECT_PULL_DIAG_SCRIPT" "$DIAG_DIR" >/dev/null
fi

diag_path="$(cd "$DIAG_DIR" && pwd)"
mirror_summary="${DIAG_DIR}/mirror/summary.tsv"

timestamp="$(summary_value_or_default timestamp_utc unknown)"
namespace="$(summary_value_or_default namespace unknown)"
pod_name="$(summary_value_or_default pod_name unknown)"
node="$(summary_value_or_default node unknown)"
phase="$(summary_value_or_default phase unknown)"
classification="$(summary_value_or_default classification unknown)"
rung_b_image="$(summary_value_or_default rung_b_image unknown)"
rung_b_key_id="$(summary_value_or_default rung_b_key_id unknown)"
host_pull_blocker_seen="$(summary_value_or_default host_pull_blocker_seen unknown)"
image_key_request_seen="$(summary_value_or_default image_key_request_seen unknown)"
repo_head="$(summary_value_or_default repo_git_head unknown)"
repo_branch="$(summary_value_or_default repo_git_branch unknown)"
repo_dirty="$(summary_value_or_default repo_git_dirty unknown)"
crio_since="$(summary_value_or_default crio_log_since_time unknown)"
mirror_since="$(summary_value_or_default mirror_log_since_time unknown)"
manifest_path="$(summary_value_or_default rung_bc_images_manifest unknown)"
env_path="$(summary_value_or_default rung_bc_env_file unknown)"

if [[ -s "$mirror_summary" ]]; then
	crio_manifest="$(tsv_value_or_default "$mirror_summary" crio_rung_b_manifest unknown)"
	crio_blob="$(tsv_value_or_default "$mirror_summary" crio_rung_b_blob unknown)"
	guest_manifest="$(tsv_value_or_default "$mirror_summary" guest_rung_b_manifest unknown)"
	guest_blob="$(tsv_value_or_default "$mirror_summary" guest_rung_b_blob unknown)"
else
	crio_manifest="$(summary_value_or_default mirror_crio_rung_b_manifest_count unknown)"
	crio_blob="$(summary_value_or_default mirror_crio_rung_b_blob_count unknown)"
	guest_manifest="$(summary_value_or_default mirror_guest_rung_b_manifest_count unknown)"
	guest_blob="$(summary_value_or_default mirror_guest_rung_b_blob_count unknown)"
fi

cat <<EOF
## Rung-b direct-pull diagnostic

- Evidence directory: \`${diag_path}\`
- Validator: \`make validate-rung-b-direct-pull DIAG_DIR=${diag_path}\`
- Validation: passed with \`REQUIRE_MIRROR_SUMMARY=${REQUIRE_MIRROR_SUMMARY}\`
- Timestamp: \`${timestamp}\`
- Pod: \`${namespace}/${pod_name}\` on node \`${node}\`, phase \`${phase}\`
- Rung-b image: \`${rung_b_image}\`
- Rung-b key ID: \`${rung_b_key_id}\`
- Repo provenance: branch \`${repo_branch}\`, head \`${repo_head}\`, dirty \`${repo_dirty}\`
- Log windows: CRI-O since \`${crio_since}\`, mirror since \`${mirror_since}\`
- Artifact handoff: \`${manifest_path}\` and \`${env_path}\`

Key signals:

\`\`\`text
classification=${classification}
host_pull_blocker_seen=${host_pull_blocker_seen}
image_key_request_seen=${image_key_request_seen}
crio_rung_b_manifest=${crio_manifest}
crio_rung_b_blob=${crio_blob}
guest_rung_b_manifest=${guest_manifest}
guest_rung_b_blob=${guest_blob}
\`\`\`

Interpretation: CRI-O host-side image handling pulled the encrypted rung-b manifest/blob and hit
the known encrypted-layer blocker before Kata guest pull began. Trustee did not receive the rung-b
image-key request, and the guest \`oci-client\` did not pull the rung-b image in this diagnostic
window.
EOF
