#!/usr/bin/env bash
# Hands-off A->C reproducibility loop (issue #22). For each capability rung it chains
# deploy -> POSITIVE (happy path) -> NEGATIVE (denial) via scripts/test-rung.sh, then moves to the
# next rung — no manual steps. Progress is written to a DURABLE status file so an interrupted run
# RESUMES (rungs already recorded PASS are skipped) instead of restarting from A.
#
# Scope: A (rung-kbs) -> B (rung-rvps) -> C (rung-signed) + the cross-cutting air-gap negative.
# rung-encrypted (D) is MANUAL / upstream-blocked (cri-o/cri-o#10084) — it is logged-skipped here,
# NEVER run and NEVER counted as a failure (run it by hand: `make test-rung WHICH=rung-encrypted`).
#
# Usage: ./scripts/repro-loop.sh [--fresh]
#   --fresh (or REPRO_FRESH=1)  start a new run: truncate the status file first.
# Env: REPRO_STATUS_FILE=<path>  durable status file (default loop-runs/repro-status.tsv, git-ignored)
#      RUNG_SIGNED_IMAGE / RUNG_SIGNED_UNSIGNED_IMAGE  digest refs for the rung-signed proofs
#      plus everything test-rung.sh / negative-test.sh honor (NS, MIRROR_REGISTRY, KBS_URL, TIMEOUT...).
# Exit: 0 = every rung PASS or by-design SKIP (rvps->#18, encrypted->#20) — loop is green;
#       1 = a rung's positive or negative proof FAILED (stops on the first hard failure);
#       3 = a rung could not run (missing prerequisite) — fix and re-run to resume.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_RUNG_SCRIPT="${TEST_RUNG_SCRIPT:-$REPO_ROOT/scripts/test-rung.sh}"
NEGATIVE_TEST_SCRIPT="${NEGATIVE_TEST_SCRIPT:-$REPO_ROOT/scripts/negative-test.sh}"
STATUS_FILE="${REPRO_STATUS_FILE:-$REPO_ROOT/loop-runs/repro-status.tsv}"
FRESH="${REPRO_FRESH:-0}"
[[ "${1:-}" == "--fresh" ]] && FRESH=1

# A -> C hands-off; rung-encrypted (D) is deliberately excluded (manual/upstream-blocked).
RUNGS="rung-kbs rung-rvps rung-signed"

die()  { echo "ERROR: $*" >&2; exit 2; }
now()  { date -u +%FT%TZ; }
recorded_pass() { [[ -f "$STATUS_FILE" ]] && grep -qE "^$1	PASS	" "$STATUS_FILE"; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$(now)" >> "$STATUS_FILE"; }   # <step>\t<PASS|SKIP|FAIL>\t<ts>

command -v oc >/dev/null || die "oc not on PATH"
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"

mkdir -p "$(dirname "$STATUS_FILE")"
if [[ "$FRESH" == "1" ]]; then : > "$STATUS_FILE"; echo "repro-loop: fresh run — status reset ($STATUS_FILE)"; fi
echo "repro-loop start $(now) — durable status: $STATUS_FILE"

hard_fail=0 prereq=0 ran=0 passed=0 skipped=0

# run_step <step-label> <command...>: run one proof step, map its exit code, record it durably.
# Resumes: a step already recorded PASS is skipped. Stops the loop on the first hard FAIL.
run_step() {
  local step="$1"; shift
  if recorded_pass "$step"; then echo "==== [$step] already PASS (resume) — skipping ===="; passed=$((passed+1)); return 0; fi
  echo "==== [$step] deploy -> positive -> negative ===="
  local rc=0
  "$@" || rc=$?
  case "$rc" in
    0) record "$step" PASS; passed=$((passed+1)); echo "[$step] PASS" ;;
    3) record "$step" SKIP; skipped=$((skipped+1)); echo "[$step] SKIP (by-design or missing prerequisite — see output above)"; prereq=1 ;;
    *) record "$step" FAIL; echo "[$step] FAIL (exit $rc) — stopping the loop so the finding surfaces"; hard_fail=1 ;;
  esac
  ran=$((ran+1))
  return "$rc"
}

for rung in $RUNGS; do
  run_step "$rung" bash "$TEST_RUNG_SCRIPT" "$rung" || { [[ "$hard_fail" == "1" ]] && break; }
done
# Cross-cutting air-gap negative (the VCEK OfflineStore is load-bearing) — only if no hard failure yet.
if [[ "$hard_fail" == "0" ]]; then
  run_step "air-gap" bash "$NEGATIVE_TEST_SCRIPT" air-gap || true
fi
# rung-encrypted (D): manual / upstream-blocked — logged skip, never a failure.
if ! recorded_pass "rung-encrypted"; then
  echo "==== [rung-encrypted] SKIPPED (manual / upstream-blocked cri-o/cri-o#10084, #20) ===="
  record "rung-encrypted" SKIP; skipped=$((skipped+1))
fi

echo
echo "repro-loop summary $(now): ${passed} passed, ${skipped} skipped, $([[ $hard_fail == 1 ]] && echo 1 || echo 0) failed."
echo "  (durable status in $STATUS_FILE — re-run to resume; --fresh to restart)"
(( hard_fail == 0 )) || { echo "REPRO-LOOP FAIL: a rung's proof did not hold — sign-off blocker."; exit 1; }
(( prereq == 0 ))    || { echo "REPRO-LOOP INCOMPLETE: a rung skipped on a missing prerequisite (rung-rvps overlay is wired in #18); fix and re-run to resume."; exit 3; }
echo "REPRO-LOOP GREEN: A->C proven hands-off (rung-encrypted/D manual, logged-skipped)."
