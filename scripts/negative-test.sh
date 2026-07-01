#!/usr/bin/env bash
# Per-rung DENIAL proofs for the CoCo rig (docs/design/engagement-design.md §5).
#
# The whole point of a negative test is that it must FAIL-CLOSED: if a workload that should be
# denied actually RUNS (secret released / image pulled), that is a sign-off-blocking finding,
# NOT a pass. This harness therefore inverts the usual success criterion — a started pod = FAIL.
#
# Hardware-bound: needs `oc` logged into a running CoCo cluster (kata-cc runtimeclass present).
#
# Usage: ./scripts/negative-test.sh [all|rung-a|rung-c|rung-b|air-gap]
# Env: NS=default  TRUSTEE_NS=trustee-operator-system  TIMEOUT=120  KEEP_DENIED_PODS=0
#      MIRROR_REGISTRY=mirror.rig.local:8443  RUNG_C_IMAGE=...  RUNG_B_UNSIGNED_IMAGE=...
#      RUNG_C_POLICY_URI=...  RUNG_B_POLICY_URI=...
#      Source rung-bc-artifacts/rung-bc.env after make build-rung-images for digest refs.
set -euo pipefail

WHICH="${1:-all}"
NS="${NS:-default}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
TIMEOUT="${TIMEOUT:-120}"
KEEP_DENIED_PODS="${KEEP_DENIED_PODS:-0}"
MIRROR_REGISTRY="${ARTIFACTORY_REGISTRY:-${MIRROR_REGISTRY:-mirror.rig.local:8443}}"  # endpoint seam (#26): ARTIFACTORY_REGISTRY canonical, MIRROR_REGISTRY legacy alias
MIRROR_DNS_UPSTREAM="${MIRROR_DNS_UPSTREAM:-192.168.66.10}"
KBS_URL="${KBS_URL:-http://kbs-service.${TRUSTEE_NS}.svc:8080}"
RUNG_C_POLICY_URI="${RUNG_C_POLICY_URI:-kbs:///default/security-policy/test}"
RUNG_B_POLICY_URI="${RUNG_B_POLICY_URI:-kbs:///default/security-policy/rung-b}"
RUNG_C_IMAGE="${RUNG_C_IMAGE:-${MIRROR_REGISTRY}/coco/rung-c:encrypted}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/compat.sh
source "${REPO_ROOT}/scripts/lib/compat.sh"
pass=0 fail=0 skip=0
# Denial-RESPONSE patterns ONLY. These are the load-bearing oracle: a match = "denied as
# expected" = PASS. They are grepped against pod EVENTS + pod LOGS + Trustee LOGS (NOT
# `oc describe pod`, which echoes the workload's own spec). Each alternative must be a real
# denial string, never a word that appears in the pod spec or a benign lifecycle event —
# a bare `attest` matches the init-container name "attestation-gate", `sign` matches the
# scheduler's "Successfully a-ssign-ed" event, and `policy`/`secret` match routine KBS log
# lines; any of those would score a false PASS on a fail-closed proof.
RUNG_A_DENIAL_RE='denied|forbidden|unauthorized|PolicyDeny|measurement|HTTP/[0-9.]+" (401|403)|failed to get resource|report data|attestation (failed|error|denied)|Verifier.*(fail|reject)'
RUNG_C_DENIAL_RE='attestation.*(denied|failed|error)|failed.*attest|denied|forbidden|measurement|unauthorized|not authorized|HTTP/[0-9.]+" (401|403)|resource/default/image-(kek|key).*(401|403)'
RUNG_B_DENIAL_RE='signature|sigstore|image security policy|SignatureValidation|signature.*(reject|invalid|missing|verif)|policy.*(reject|deny)|rejected|InvalidImageName'
AIR_GAP_DENIAL_RE='denied|forbidden|unauthorized|PolicyDeny|HTTP/[0-9.]+" (401|403)|RcarAttestFailed|verify TEE evidence failed|[Cc]ertificate chain.*(fail|verif)|does not sign|failed to get resource|vcek|offline|Verifier.*(fail|reject)|attestation (failed|error|denied)'

die()  { echo "ERROR: $*" >&2; exit 2; }
ok()   { echo "  ✅ PASS (denied as expected): $*"; pass=$((pass+1)); }
bad()  { echo "  ❌ FAIL (NOT denied — sign-off blocker): $*"; fail=$((fail+1)); }
skipt(){ echo "  ⏭️  SKIP: $*"; skip=$((skip+1)); }

command -v oc >/dev/null || die "oc not on PATH"
oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
oc get runtimeclass kata-cc >/dev/null 2>&1 || die "kata-cc runtimeclass missing — finish Phase 4 first"

denial_signal_seen() {
  local name="$1" pattern="$2" since_time="$3" context
  # Corpus is deliberately the runtime denial signal only. We do NOT include `oc describe pod`
  # because it echoes the pod spec (init-container name, the curl command path) verbatim, which
  # made spec strings match the denial regex and produced false PASSes. Instead we pull the
  # container waiting reasons/messages (real denial state) plus events + logs.
  context="$(
    oc -n "$NS" get pod "$name" -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{.state.waiting.message}{"\n"}{end}{range .status.initContainerStatuses[*]}{.state.waiting.reason}{" "}{.state.waiting.message}{"\n"}{end}' 2>/dev/null || true
    oc -n "$NS" get events --field-selector "involvedObject.name=${name}" --sort-by=.lastTimestamp -o wide 2>/dev/null || true
    oc -n "$NS" logs "pod/${name}" --all-containers --prefix=true --tail=80 2>/dev/null || true
    oc -n "$TRUSTEE_NS" logs deployment/trustee-deployment --since-time="$since_time" --tail=240 2>/dev/null || true
  )"
  grep -qiE "$pattern" <<<"$context"
}

# Deploy a workload and assert it FAILS-CLOSED: the pod must NOT reach Running/Succeeded within
# TIMEOUT (attestation denies the secret/key/pull). If it DOES start, that's the bad case.
expect_fail_closed() {  # expect_fail_closed <name> <manifest-or-"-"> <label> <denial-pattern> <signal-label>
  local name="$1" manifest="$2" label="$3" pattern="$4" signal_label="$5" since_time
  oc -n "$NS" delete pod "$name" --ignore-not-found --wait >/dev/null 2>&1 || true
  since_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
  # never started within the window - confirm this rung's expected denial signal, not a flake
  local inconclusive=0
  if denial_signal_seen "$name" "$pattern" "$since_time"; then
    ok "$label"
  else
    echo "  ⚠️  pod '$name' did not start, but no ${signal_label} signal seen — investigate (could be a flake or the wrong dependency failing)"; bad "$label (no ${signal_label} signal)"
    inconclusive=1
  fi
  # Keep the pod when KEEP_DENIED_PODS=1, OR when the result was inconclusive — deleting the
  # evidence right after telling the operator to "investigate" would destroy what they need.
  if [[ "$KEEP_DENIED_PODS" == "1" || "$inconclusive" == "1" ]]; then
    if [[ "$inconclusive" == "1" ]]; then
      echo "  (keeping pod '$name' for investigation — no clear denial signal)"
    else
      echo "  (keeping denied pod '$name' for evidence collection)"
    fi
  else
    oc -n "$NS" delete pod "$name" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

render_or_skip() { # render_or_skip <label> <output-file> <command...>
  local label="$1" out="$2" err
  shift 2
  err="$(mktemp)"
  if "$@" > "$out" 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  echo "  render failed for ${label}:"
  sed 's/^/    /' "$err"
  rm -f "$err"
  skipt "${label}: render failed (missing image artifacts, mirror CA, oc client, or initdata inputs)"
  return 1
}

# control_released <pod>: 0 if the secret was released, else 1. The release actually happens in the
# attestation-gate INIT container, so key on ITS exit code (exit 0 = got the secret) rather than only
# full pod-Ready — otherwise a slow/unrelated app-container start on slower-than-the-rig hardware would
# be misread as "withheld" and produce a misleading SKIP. Non-zero init exit = withheld (early-out).
control_released() {
  local name="$1" deadline=$(( SECONDS + TIMEOUT )) ec ready
  while (( SECONDS < deadline )); do
    ec="$(oc -n "$NS" get pod "$name" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}' 2>/dev/null)"
    [[ "$ec" == "0" ]] && return 0
    [[ -n "$ec" && "$ec" != "0" ]] && return 1
    ready="$(oc -n "$NS" get pod "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$ready" == "True" ]] && return 0
    sleep 5
  done
  return 1
}

# rung-a is SELF-CONTAINED (mirrors the air-gap swap-and-restore): the base attestation-policy is
# permissive by design (`default configuration := 2`, resource-policy `allow := true`), so an
# init-data tamper alone changes HOST_DATA but nothing gates on it. Here we temporarily apply a
# RESTRICTIVE measured-initdata policy (configuration affirmed ONLY when input.init_data == the
# sha256 of the exact initdata bytes; the rung-a secret released ONLY when configuration is affirmed),
# then:
#   CONTROL  — untampered pod MUST release (proves the digest matches this build's measured HOST_DATA;
#              a false-pass guard: if it doesn't release we SKIP, never claim a tamper denial), and
#   NEGATIVE — tampered pod MUST be withheld.
# Base policies are backed up (data-only) and ALWAYS restored (trap), so the rig returns to baseline.
# Proven on the rig 2026-07-01: untampered RELEASED, tampered WITHHELD (HTTP 403), base restored.
run_rung_a() {
  echo "[rung-a] secret release — restrictive measured-initdata policy: untampered RELEASES, tampered WITHHELD (apply+revert)"
  # restore_needed / bakdir / manifest_ctrl / manifest_neg are intentionally GLOBAL, NOT local: the
  # EXIT backstop (rung_a_exit_cleanup) fires at GLOBAL scope after a `set -e` unwind, where this
  # function's locals no longer exist. A local restore_needed would read unbound there — fatal under
  # `set -u`, so the trap would die BEFORE restoring and leave the rig stuck on the restrictive
  # policy (the exact rig-breaking failure this backstop exists to prevent). Globals + the `:-`
  # default guards below keep the trap able to restore no matter which command triggered the abort.
  local initdata_file restrictive digest base_ap base_rp
  local resource_uri="${RUNG_A_RESOURCE_URI:-kbs:///default/attestation-status/status}"
  have_sha256 || { skipt "rung-a: a sha256 tool is required for the measured-initdata gate"; return; }

  restore_needed=0
  bakdir="$(mktemp -d)"; manifest_ctrl="$(mktemp)"; manifest_neg="$(mktemp)"
  initdata_file="$bakdir/initdata.toml"; restrictive="$bakdir/restrictive.yaml"

  rung_a_restore() {
    [[ "${restore_needed:-0}" == "1" ]] || return 0
    echo "  (restoring base attestation-policy + resource-policy)"
    oc -n "$TRUSTEE_NS" apply -f "${bakdir}/attestation-policy.yaml" >/dev/null 2>&1 || true
    oc -n "$TRUSTEE_NS" apply -f "${bakdir}/resource-policy.yaml" >/dev/null 2>&1 || true
    restart_kbs
    restore_needed=0
  }
  _rung_a_finish() {  # explicit teardown for every return path (EXIT trap is only a crash backstop)
    rung_a_restore
    oc -n "$NS" delete pod negtest-rung-a-ctrl negtest-rung-a --ignore-not-found --wait=false >/dev/null 2>&1 || true
    trap - EXIT
    rm -rf "${bakdir:-}"; rm -f "${manifest_ctrl:-}" "${manifest_neg:-}"
  }
  rung_a_exit_cleanup() { local rc=$?; rung_a_restore || true; rm -rf "${bakdir:-}"; rm -f "${manifest_ctrl:-}" "${manifest_neg:-}"; exit "$rc"; }

  # Back up base policies as clean, apply-able (data-only) manifests.
  base_ap="$(oc -n "$TRUSTEE_NS" get cm attestation-policy -o jsonpath='{.data.default_cpu\.rego}' 2>/dev/null || true)"
  base_rp="$(oc -n "$TRUSTEE_NS" get cm resource-policy   -o jsonpath='{.data.policy\.rego}'      2>/dev/null || true)"
  if [[ -z "$base_ap" || -z "$base_rp" ]]; then
    skipt "rung-a: base attestation-policy/resource-policy not found in $TRUSTEE_NS — deploy Trustee first"; _rung_a_finish; return
  fi
  printf '%s' "$base_ap" > "$bakdir/attestation.rego"
  printf '%s' "$base_rp" > "$bakdir/resource.rego"
  oc -n "$TRUSTEE_NS" create cm attestation-policy --from-file=default_cpu.rego="$bakdir/attestation.rego" --dry-run=client -o yaml > "$bakdir/attestation-policy.yaml"
  oc -n "$TRUSTEE_NS" create cm resource-policy   --from-file=policy.rego="$bakdir/resource.rego"          --dry-run=client -o yaml > "$bakdir/resource-policy.yaml"

  # Untampered measured-initdata digest — must match the CONTROL/NEGATIVE pods byte-for-byte, so use
  # the SAME env apply-rung-a.sh renders the pods with (render_initdata is deterministic).
  if ! render_or_skip "rung-a untampered initdata" "$initdata_file" \
      env EMIT_INITDATA=1 TAMPER_INITDATA=0 NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
        MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" \
        bash "$REPO_ROOT/scripts/apply-rung-a.sh"; then _rung_a_finish; return; fi
  digest="$(sha256_file "$initdata_file")"

  # Restrictive policy gating the rung-a secret path on that digest (the renderer is generic — the
  # gated resource is whatever RUNG_C_KEY_ID points at; its rego identifiers just read 'image_key').
  if ! render_or_skip "rung-a restrictive policy" "$restrictive" \
      env RUNG_C_KEY_ID="$resource_uri" NS="$TRUSTEE_NS" \
        bash "$REPO_ROOT/scripts/render-rung-c-measurement-policy.sh" "$initdata_file"; then _rung_a_finish; return; fi
  if ! grep -q "$digest" "$restrictive"; then
    skipt "rung-a: rendered policy is missing the initdata digest (renderer/initdata mismatch)"; _rung_a_finish; return
  fi

  # From here we MUTATE cluster policy — arm the crash backstop, then apply + wait until it is LIVE.
  restore_needed=1; trap rung_a_exit_cleanup EXIT
  echo "  applying restrictive measured-initdata policy (gating $resource_uri); will revert"
  if ! oc -n "$TRUSTEE_NS" apply -f "$restrictive" >/dev/null; then
    skipt "rung-a: failed to apply restrictive policy"; _rung_a_finish; return
  fi
  restart_kbs
  if ! oc -n "$TRUSTEE_NS" get cm resource-policy -o jsonpath='{.data.policy\.rego}' 2>/dev/null | grep -q 'default allow := false'; then
    skipt "rung-a: restrictive policy not live after apply+restart — cannot trust the negative"; _rung_a_finish; return
  fi

  # CONTROL: untampered MUST release under the restrictive policy (false-pass guard).
  if ! render_or_skip "rung-a control manifest" "$manifest_ctrl" \
      env NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
        MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" \
        POD_NAME=negtest-rung-a-ctrl TAMPER_INITDATA=0 RENDER_ONLY=1 \
        bash "$REPO_ROOT/scripts/apply-rung-a.sh"; then _rung_a_finish; return; fi
  oc -n "$NS" delete pod negtest-rung-a-ctrl --ignore-not-found --wait >/dev/null 2>&1 || true
  if ! oc -n "$NS" apply -f "$manifest_ctrl" >/dev/null; then
    skipt "rung-a: failed to apply the control pod — cannot run the negative"; _rung_a_finish; return
  fi
  if control_released negtest-rung-a-ctrl; then
    echo "  control OK: untampered secret released under the restrictive policy (digest matches HOST_DATA)"
    oc -n "$NS" delete pod negtest-rung-a-ctrl --ignore-not-found >/dev/null 2>&1 || true
  else
    skipt "rung-a: the restrictive policy ALSO withheld the UNTAMPERED secret — the measured-initdata digest does not match this build's HOST_DATA, so a tamper denial can't be attributed to the tamper. Not a sign-off pass; investigate the init_data measurement."
    oc -n "$NS" delete pod negtest-rung-a-ctrl --ignore-not-found >/dev/null 2>&1 || true
    _rung_a_finish; return
  fi

  # NEGATIVE: tampered MUST be withheld under the same restrictive policy.
  if render_or_skip "rung-a negative manifest" "$manifest_neg" \
      env NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
        MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" \
        POD_NAME=negtest-rung-a TAMPER_INITDATA=1 RENDER_ONLY=1 \
        bash "$REPO_ROOT/scripts/apply-rung-a.sh"; then
    expect_fail_closed "negtest-rung-a" "$manifest_neg" "rung-a measured-initdata tamper withheld the secret under the restrictive policy" "$RUNG_A_DENIAL_RE" "rung-a attestation/resource denial"
  fi

  _rung_a_finish
}

run_rung_c() {
  echo "[rung-c] encrypted image — tamper measured initdata so image key is withheld"
  local manifest
  manifest="$(mktemp)"
  if ! render_or_skip "rung-c negative manifest" "$manifest" \
      env NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
        MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" RUNG_C_IMAGE="$RUNG_C_IMAGE" \
        IMAGE_SECURITY_POLICY_URI="$RUNG_C_POLICY_URI" POD_NAME=negtest-rung-c TAMPER_INITDATA=1 RENDER_ONLY=1 \
        bash "$REPO_ROOT/scripts/apply-rung-c.sh"; then
    rm -f "$manifest"
    return
  fi
  expect_fail_closed "negtest-rung-c" "$manifest" "rung-c measured-initdata mismatch withheld image key" "$RUNG_C_DENIAL_RE" "rung-c attestation/image-key denial"
  rm -f "$manifest"
}

run_rung_b() {
  echo "[rung-b] signed image — use unsigned/tampered image so image_security_policy rejects"
  local unsigned_image manifest
  unsigned_image="${RUNG_B_UNSIGNED_IMAGE:-${MIRROR_REGISTRY}/coco/rung-b-unsigned:unsigned}"
  manifest="$(mktemp)"
  if ! render_or_skip "rung-b negative manifest" "$manifest" \
      env NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
        MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" \
        IMAGE_SECURITY_POLICY_URI="$RUNG_B_POLICY_URI" POD_NAME=negtest-rung-b RUNG_B_IMAGE="$unsigned_image" RENDER_ONLY=1 \
        bash "$REPO_ROOT/scripts/apply-rung-b.sh"; then
    rm -f "$manifest"
    return
  fi
  expect_fail_closed "negtest-rung-b" "$manifest" "rung-b unsigned image rejected by image_security_policy" "$RUNG_B_DENIAL_RE" "rung-b signature/policy denial"
  rm -f "$manifest"
}

# Restart the Trustee KBS so it re-mounts the (now removed/restored) VCEK secrets, and WAIT for the
# new pod. Target the deployment BY NAME: the `app=kbs` label is on the POD, not the deployment, so
# `rollout restart deploy -l app=kbs` matched nothing — a no-op that exits 0, skipping the pod-delete
# fallback — leaving the deleted VCEK still mounted in the running pod, so the air-gap denial could
# never actually hold (a false FAIL on a real OfflineStore).
restart_kbs() {
  # WAIT for the SERVING KBS pod to actually rotate, not just for `rollout status` — which races:
  # it can report the OLD ReplicaSet complete before the restart's new rollout is observed, so a
  # policy/secret swap applied just before this call would NOT yet be live when the caller proceeds
  # (proven on the rig: a 1-second "restart" left the old policy serving). Capture the old pod UID,
  # restart, then block until a DIFFERENT pod is Running+Ready, then settle so KBS re-reads its
  # mounted policy/VCEK configmaps+secrets.
  local old new deadline confirmed=0
  old="$(oc -n "$TRUSTEE_NS" get pods -l app=kbs -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)"
  oc -n "$TRUSTEE_NS" rollout restart deployment/trustee-deployment >/dev/null 2>&1 || true
  sleep 6  # let the deployment controller OBSERVE the restart before rollout status is trustworthy
  oc -n "$TRUSTEE_NS" rollout status deployment/trustee-deployment --timeout=150s >/dev/null 2>&1 || true
  deadline=$(( SECONDS + 150 ))
  while (( SECONDS < deadline )); do
    new="$(oc -n "$TRUSTEE_NS" get pods -l app=kbs --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)"
    if [[ -n "$new" && "$new" != "$old" ]] && \
       oc -n "$TRUSTEE_NS" wait pod -l app=kbs --for=condition=Ready --timeout=10s >/dev/null 2>&1; then
      confirmed=1; break
    fi
    sleep 5
  done
  # Surface an unconfirmed rotation: not fatal (the callers fail SAFE — on apply, a still-permissive
  # KBS makes the tampered NEGATIVE pod RUN, which reports as a loud FAIL not a silent false PASS; on
  # restore, the durable base configmap is already applied), but the operator should know KBS may not
  # have reloaded yet (e.g. old UID was empty, or a second pre-existing kbs pod matched).
  [[ "$confirmed" == "1" ]] || echo "  ⚠️  restart_kbs: could not confirm the KBS pod rotated within 150s — proceeding (results still fail-safe)"
  sleep 10  # settle: KBS loads policy/secrets from the mounted configmaps+secrets on startup
}

run_air_gap() {
  echo "[air-gap] swap VCEK for a WRONG cert → OfflineStore present-but-wrong → attestation must fail (not silently hit KDS)"
  # vceks/bakdir/manifest/restore_needed are GLOBAL (not local): the EXIT backstop restores at global
  # scope after a `set -e` unwind, where locals are gone — a local restore_needed reads unbound under
  # `set -u` and the trap dies before restoring, leaving the bogus wrong-cert VCEK live and attestation
  # broken cluster-wide until manual repair (same failure class fixed in run_rung_a above).
  local vcek bogus
  vceks=()
  while IFS= read -r vcek_line; do vceks+=("$vcek_line"); done < <(oc -n "$TRUSTEE_NS" get secret -o name 2>/dev/null | grep '^secret/vcek-' || true)
  if [[ "${#vceks[@]}" -eq 0 ]]; then skipt "no vcek-* secret in $TRUSTEE_NS — run make collect-vcek first"; return; fi
  command -v openssl >/dev/null || { skipt "openssl required to mint the wrong VCEK for the air-gap test"; return; }
  restore_needed=0
  bakdir="$(mktemp -d)"
  manifest="$(mktemp)"

  air_gap_restore() {
    local backup name
    [[ "${restore_needed:-0}" == "1" ]] || return 0
    echo "  (restoring ${#vceks[@]} VCEK secret(s))"
    for backup in "${bakdir}"/*.der; do
      [[ -e "$backup" ]] || continue
      name="$(basename "$backup" .der)"
      oc -n "$TRUSTEE_NS" create secret generic "$name" --from-file=vcek.der="$backup" --dry-run=client -o yaml \
        | oc -n "$TRUSTEE_NS" apply -f - >/dev/null || true
    done
    restart_kbs
    restore_needed=0
  }

  air_gap_exit_cleanup() {
    local rc=$?
    air_gap_restore || true
    rm -rf "${bakdir:-}"
    rm -f "${manifest:-}"
    exit "$rc"
  }

  for vcek in "${vceks[@]}"; do
    # Back up only the vcek.der DATA (not `get -o yaml`): restoring via create|apply avoids the
    # resourceVersion/managedFields Conflict that `oc apply` of a full backup hits once the swap
    # below bumps the live secret — which would otherwise leave the OfflineStore holding the wrong cert.
    oc -n "$TRUSTEE_NS" get "$vcek" -o jsonpath='{.data.vcek\.der}' 2>/dev/null | b64_decode > "$bakdir/${vcek#secret/}.der"
  done
  restore_needed=1
  trap air_gap_exit_cleanup EXIT

  # Mint a valid-but-WRONG cert (parseable DER, so KBS still starts) and put it in the OfflineStore.
  # Do NOT delete the secret: the kbsLocalCertCacheSpec volume is REQUIRED, so a missing secret leaves
  # KBS unable to start — and KBS-down is NOT the same as attestation-denied. A present-but-wrong cert
  # keeps KBS up and makes the SNP verifier reject the report's cert chain → a clean, real OfflineStore
  # denial (verified on the rig: `POST /kbs/v0/attest 401`, "Certificate chain from KDS failed verification").
  bogus="$bakdir/wrong-vcek.der"
  openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out "$bakdir/wrong-vcek.pem" -days 1 -nodes -subj /CN=wrong-vcek >/dev/null 2>&1
  openssl x509 -in "$bakdir/wrong-vcek.pem" -outform der -out "$bogus" >/dev/null 2>&1
  echo "  (replacing ${#vceks[@]} VCEK secret(s) with a wrong cert; will restore)"
  for vcek in "${vceks[@]}"; do
    oc -n "$TRUSTEE_NS" create secret generic "${vcek#secret/}" --from-file=vcek.der="$bogus" --dry-run=client -o yaml \
      | oc -n "$TRUSTEE_NS" apply -f - >/dev/null
  done
  restart_kbs
  sleep 5
  if render_or_skip "air-gap happy-path rung-a manifest" "$manifest" \
      env NS="$NS" TRUSTEE_NS="$TRUSTEE_NS" MIRROR_REGISTRY="$MIRROR_REGISTRY" \
        MIRROR_DNS_UPSTREAM="$MIRROR_DNS_UPSTREAM" KBS_URL="$KBS_URL" \
        POD_NAME=negtest-air-gap RENDER_ONLY=1 \
        bash "$REPO_ROOT/scripts/apply-rung-a.sh"; then
    expect_fail_closed "negtest-air-gap" "$manifest" "air-gap wrong-VCEK denied otherwise happy rung-a" "$AIR_GAP_DENIAL_RE" "air-gap VCEK/OfflineStore denial"
  fi
  air_gap_restore
  rm -rf "$bakdir"
  rm -f "$manifest"
  trap - EXIT
}

case "$WHICH" in
  rung-a)  run_rung_a ;;
  air-gap) run_air_gap ;;
  rung-c)  run_rung_c ;;
  rung-b)  run_rung_b ;;
  all)
    run_rung_a
    run_rung_c
    run_rung_b
    run_air_gap ;;
  *) die "unknown target '$WHICH' (use: all|rung-a|rung-c|rung-b|air-gap)" ;;
esac

echo
echo "negative-test summary: ${pass} passed, ${fail} failed, ${skip} skipped."
(( fail == 0 )) || { echo "FAIL: a denial did not hold — treat as a sign-off blocker."; exit 1; }
(( skip == 0 )) || { echo "INCOMPLETE: ${skip} rung(s) not covered; fix the reported prerequisites and rerun."; exit 3; }
echo "All denial proofs held."
