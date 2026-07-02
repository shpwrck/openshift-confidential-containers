#!/usr/bin/env bash
# Per-rung POSITIVE + NEGATIVE proof runner for the CoCo rig (issue #21), symmetric to
# scripts/negative-test.sh (docs/design/engagement-design.md §5).
#
# Every rung has TWO proofs and is "proven" only when BOTH are green:
#   POSITIVE — the happy path MUST succeed (fail-OPEN): secret released / signed image runs.
#              Delegated to the apply-rung-*.sh scripts (they delete + redeploy + wait Ready).
#   NEGATIVE — the denial MUST hold (fail-CLOSED). Delegated to scripts/negative-test.sh.
#
# Rung model (docs present the ladder A -> B -> C -> D):
#   A rung-kbs       secret release          — pos+neg run here
#   B rung-rvps      measurement verification — SKELETON: skips until the RVPS overlay is wired (#18)
#   C rung-signed    signed image            — pos+neg run here
#   D rung-encrypted encrypted image         — MANUAL / upstream-blocked (cri-o/cri-o#10084); reported
#                                              skipped, NEVER failed (#20)
#
# Usage: ./scripts/test-rung.sh [all|rung-kbs|rung-rvps|rung-signed|rung-encrypted]
# Env: NS=default  TRUSTEE_NS=trustee-operator-system  MIRROR_REGISTRY(/ARTIFACTORY_REGISTRY)
#      KBS_URL  TIMEOUT (negative)  KEEP_DENIED_PODS
#      RUNG_SIGNED_IMAGE=<@sha256 digest ref>  required for the rung-signed positive
#        (source rung-image-artifacts/rung-signed.env, or pass the digest of the running signed image)
# Exit: 0 = every attempted proof held (rung-rvps/#18 + rung-encrypted/#20 skips are expected);
#       1 = a positive or negative proof was VIOLATED (sign-off blocker);
#       3 = incomplete — a prerequisite was missing so a proof could not run (fix and rerun).
set -euo pipefail

WHICH="${1:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NS="${NS:-default}"
export TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
# Endpoint seam (#26): forward both so the child scripts resolve the mirror the same way.
export MIRROR_REGISTRY="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"
export KBS_URL="${KBS_URL:-http://kbs-service.${TRUSTEE_NS}.svc:8080}"
export TIMEOUT="${TIMEOUT:-120}"
export KEEP_DENIED_PODS="${KEEP_DENIED_PODS:-0}"
RUNG_SIGNED_IMAGE="${RUNG_SIGNED_IMAGE:-}"
# The signed positive must gate on the SAME KBS policy resource the rig serves; `make run-rung-signed`
# threads RUNG_SIGNED_POLICY_URI into IMAGE_SECURITY_POLICY_URI, so forward it here too (a rig with a
# custom signed policy would otherwise be proven against apply-rung-image.sh's default).
RUNG_SIGNED_POLICY_URI="${RUNG_SIGNED_POLICY_URI:-kbs:///default/security-policy/rung-signed}"

NEGATIVE_TEST_SCRIPT="${NEGATIVE_TEST_SCRIPT:-$REPO_ROOT/scripts/negative-test.sh}"
APPLY_RUNG_KBS_SCRIPT="${APPLY_RUNG_KBS_SCRIPT:-$REPO_ROOT/scripts/apply-rung-kbs.sh}"
APPLY_RUNG_SIGNED_SCRIPT="${APPLY_RUNG_SIGNED_SCRIPT:-$REPO_ROOT/scripts/apply-rung-signed.sh}"

pass=0 fail=0 skip_manual=0 skip_prereq=0
die()   { echo "ERROR: $*" >&2; exit 2; }
ok()    { echo "  ✅ PASS: $*"; pass=$((pass+1)); }
bad()   { echo "  ❌ FAIL (sign-off blocker): $*"; fail=$((fail+1)); }
skipm() { echo "  ⏭️  SKIP (by design): $*"; skip_manual=$((skip_manual+1)); }   # rvps/#18, encrypted/#20
skipp() { echo "  ⚠️  SKIP (prerequisite missing): $*"; skip_prereq=$((skip_prereq+1)); }

command -v oc >/dev/null || die "oc not on PATH"
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
oc get runtimeclass kata-cc >/dev/null 2>&1 || die "kata-cc runtimeclass missing — finish Phase 4 first"

# run_positive <label> <cmd...>: the happy path MUST exit 0 (fail-OPEN). Output is captured and the
# tail echoed indented so a green run stays quiet and a failure shows the diagnostic context.
run_positive() {
  local label="$1"; shift
  local out; out="$(mktemp)"
  echo "[$label +] positive — happy path must run (fail-OPEN)"
  if "$@" >"$out" 2>&1; then
    sed 's/^/    /' "$out" | tail -6
    ok "$label positive: happy path ran"
  else
    sed 's/^/    /' "$out" | tail -30
    bad "$label positive: happy path did NOT run"
  fi
  rm -f "$out"
}

# run_negative <which> <label>: the denial MUST hold (fail-CLOSED). Delegates to negative-test.sh and
# maps its exit code: 0=held, 3=incomplete (a prerequisite was missing), other=denial breached.
run_negative() {
  local which="$1" label="$2" rc out; out="$(mktemp)"
  echo "[$label -] negative — denial must hold (fail-CLOSED)"
  set +e
  bash "$NEGATIVE_TEST_SCRIPT" "$which" >"$out" 2>&1; rc=$?
  set -e
  sed 's/^/    /' "$out" | tail -12
  rm -f "$out"
  case "$rc" in
    0) ok "$label negative: denial held" ;;
    3) skipp "$label negative: incomplete (a prerequisite was missing) — see output above" ;;
    *) bad "$label negative: denial did NOT hold (negative-test exit $rc)" ;;
  esac
}

run_rung() {
  case "$1" in
    rung-kbs)
      # POSITIVE: the confidential (kata-cc) pod attests -> KBS releases the secret -> pod runs.
      # NEGATIVE (#17): a non-CoCo (non-kata) pod cannot attest -> secret withheld (fail-closed).
      run_positive "rung-kbs" bash "$APPLY_RUNG_KBS_SCRIPT"
      run_negative "rung-kbs" "rung-kbs (bare no-attestation / non-CoCo)"
      ;;
    rung-rvps)
      # POSITIVE: measurement present (matches the appraised HOST_DATA) -> secret released.
      # NEGATIVE (#18): valid attestation with the WRONG measurement (tampered initdata) -> withheld.
      run_positive "rung-rvps" bash "$APPLY_RUNG_KBS_SCRIPT"
      run_negative "rung-rvps" "rung-rvps"
      ;;
    rung-signed)
      if [[ "$RUNG_SIGNED_IMAGE" == *@sha256:* ]]; then
        run_positive "rung-signed" env RUNG_SIGNED_IMAGE="$RUNG_SIGNED_IMAGE" \
          IMAGE_SECURITY_POLICY_URI="$RUNG_SIGNED_POLICY_URI" bash "$APPLY_RUNG_SIGNED_SCRIPT"
      else
        skipp "rung-signed positive: set RUNG_SIGNED_IMAGE=<...@sha256:...> (source rung-image-artifacts/rung-signed.env)"
      fi
      run_negative "rung-signed" "rung-signed"
      ;;
    rung-encrypted)
      skipm "rung-encrypted positive: MANUAL / upstream-blocked (cri-o/cri-o#10084) — see #20"
      skipm "rung-encrypted negative: MANUAL — run alone with 'negative-test.sh rung-encrypted'"
      ;;
  esac
}

case "$WHICH" in
  rung-kbs)       run_rung rung-kbs ;;
  rung-rvps)      run_rung rung-rvps ;;
  rung-signed)    run_rung rung-signed ;;
  rung-encrypted) run_rung rung-encrypted ;;
  all)
    run_rung rung-kbs
    run_rung rung-rvps
    run_rung rung-signed
    # air-gap is a negative-only, cross-cutting proof (the VCEK OfflineStore is load-bearing).
    run_negative "air-gap" "air-gap"
    run_rung rung-encrypted
    ;;
  rung-a|rung-b|rung-c)
    die "retired token '$WHICH': rungs are capability-named — rung-a->rung-kbs, rung-b->rung-signed, rung-c->rung-encrypted (measurement is rung-rvps)." ;;
  *) die "unknown target '$WHICH' (use: all|rung-kbs|rung-rvps|rung-signed|rung-encrypted)" ;;
esac

echo
echo "test-rung summary: ${pass} passed, ${fail} failed, ${skip_manual} skipped(by-design), ${skip_prereq} skipped(prereq)."
(( fail == 0 )) || { echo "FAIL: a positive or negative proof did not hold — treat as a sign-off blocker."; exit 1; }
(( skip_prereq == 0 )) || { echo "INCOMPLETE: ${skip_prereq} proof(s) could not run; fix the reported prerequisites and rerun."; exit 3; }
# Report only what THIS invocation actually ran — never claim rungs that were not selected.
if (( skip_manual > 0 )); then
  echo "All attempted proofs held for WHICH=${WHICH}: ${pass} passed, ${skip_manual} skipped by design (rung-rvps->#18 / rung-encrypted->#20 are not failures)."
else
  echo "All attempted proofs held for WHICH=${WHICH}: ${pass} passed."
fi
