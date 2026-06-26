#!/usr/bin/env bash
# Per-rung DENIAL proofs for the CoCo rig (docs/design/engagement-design.md §5).
#
# The whole point of a negative test is that it must FAIL-CLOSED: if a workload that should be
# denied actually RUNS (secret released / image pulled), that is a sign-off-blocking finding,
# NOT a pass. This harness therefore inverts the usual success criterion — a started pod = FAIL.
#
# Hardware-bound: needs `oc` logged into a running CoCo cluster (kata-cc runtimeclass present).
#
# Usage: ./scripts/negative-test.sh [all|rung-a|rung-b|rung-c|air-gap]
# Env: NS=default  TRUSTEE_NS=trustee-operator-system  TIMEOUT=120
set -euo pipefail

WHICH="${1:-all}"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
TIMEOUT="${TIMEOUT:-120}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0 skip=0

die()  { echo "ERROR: $*" >&2; exit 2; }
ok()   { echo "  ✅ PASS (denied as expected): $*"; pass=$((pass+1)); }
bad()  { echo "  ❌ FAIL (NOT denied — sign-off blocker): $*"; fail=$((fail+1)); }
skipt(){ echo "  ⏭️  SKIP: $*"; skip=$((skip+1)); }

command -v oc >/dev/null || die "oc not on PATH"
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
oc get runtimeclass kata-cc >/dev/null 2>&1 || die "kata-cc runtimeclass missing — finish Phase 4 first"

# Deploy a workload and assert it FAILS-CLOSED: the pod must NOT reach Running/Succeeded within
# TIMEOUT (attestation denies the secret/key/pull). If it DOES start, that's the bad case.
expect_fail_closed() {  # expect_fail_closed <name> <manifest-or-"-"> <label>
  local name="$1" manifest="$2" label="$3"
  oc -n "$NS" delete pod "$name" --ignore-not-found --wait >/dev/null 2>&1 || true
  if [[ "$manifest" == "-" ]]; then oc -n "$NS" apply -f - >/dev/null; else oc -n "$NS" apply -f "$manifest" >/dev/null; fi
  local deadline=$(( SECONDS + TIMEOUT ))
  while (( SECONDS < deadline )); do
    local phase; phase="$(oc -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    case "$phase" in
      Running|Succeeded) bad "$label — pod '$name' reached $phase; denial did NOT hold"
                         oc -n "$NS" delete pod "$name" --ignore-not-found >/dev/null 2>&1; return ;;
    esac
    sleep 5
  done
  # never started within the window — confirm there's a denial/attestation signal, not a flake
  if oc -n "$NS" describe pod "$name" 2>/dev/null | grep -qiE 'attest|denied|forbidden|policy|sign|measurement|secret|CreateContainerError|RunContainerError'; then
    ok "$label"
  else
    echo "  ⚠️  pod '$name' did not start, but no attestation/denial signal seen — investigate (could be a flake)"; bad "$label (no denial signal)"
  fi
  oc -n "$NS" delete pod "$name" --ignore-not-found >/dev/null 2>&1 || true
}

run_rung_a() {
  echo "[rung-a] secret release — tamper so attestation cannot succeed → secret withheld"
  local src="${REPO_ROOT}/gitops/base/workloads/rung-a-secret-pod.yaml"
  [[ -f "$src" ]] || { skipt "rung-a workload manifest missing ($src)"; return; }
  # Tamper: rename to a test pod and break the attested resource path so the CDH gate fails.
  oc get -f "$src" -o yaml >/dev/null 2>&1 || true
  sed -e 's/name: .*/name: negtest-rung-a/' \
      -e 's#attestation-status/status#attestation-status/__tampered__#g' "$src" \
      | expect_fail_closed "negtest-rung-a" "-" "rung-a tampered attestation path"
}

run_air_gap() {
  echo "[air-gap] remove a VCEK secret → OfflineStore miss → attestation must fail (not silently hit KDS)"
  local vcek; vcek="$(oc -n "$TRUSTEE_NS" get secret -o name 2>/dev/null | grep -m1 'secret/vcek-' || true)"
  if [[ -z "$vcek" ]]; then skipt "no vcek-* secret in $TRUSTEE_NS — run make collect-vcek first"; return; fi
  local bak; bak="$(mktemp)"; oc -n "$TRUSTEE_NS" get "$vcek" -o yaml > "$bak"
  echo "  (temporarily removing $vcek; will restore)"
  oc -n "$TRUSTEE_NS" delete "$vcek" >/dev/null
  oc -n "$TRUSTEE_NS" rollout restart deploy -l app=kbs >/dev/null 2>&1 || oc -n "$TRUSTEE_NS" delete pod -l app=kbs >/dev/null 2>&1 || true
  sleep 10
  run_rung_a   # with the VCEK gone, the same workload must now fail-closed
  echo "  (restoring $vcek)"; oc -n "$TRUSTEE_NS" apply -f "$bak" >/dev/null; rm -f "$bak"
  oc -n "$TRUSTEE_NS" rollout restart deploy -l app=kbs >/dev/null 2>&1 || true
}

case "$WHICH" in
  rung-a)  run_rung_a ;;
  air-gap) run_air_gap ;;
  rung-b)  skipt "rung-b (encrypted image): author gitops/base/workloads/rung-b-*.yaml first" ;;
  rung-c)  skipt "rung-c (signed image): author gitops/base/workloads/rung-c-*.yaml first" ;;
  all)
    run_rung_a
    skipt "rung-b (encrypted image): workload manifest not yet authored"
    skipt "rung-c (signed image): workload manifest not yet authored"
    run_air_gap ;;
  *) die "unknown target '$WHICH' (use: all|rung-a|rung-b|rung-c|air-gap)" ;;
esac

echo
echo "negative-test summary: ${pass} passed, ${fail} failed, ${skip} skipped."
(( fail == 0 )) || { echo "FAIL: a denial did not hold — treat as a sign-off blocker."; exit 1; }
(( skip == 0 )) || { echo "INCOMPLETE: ${skip} rung(s) not yet covered (author the b/c workloads)."; exit 3; }
echo "All denial proofs held."
