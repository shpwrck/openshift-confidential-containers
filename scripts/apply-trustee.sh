#!/usr/bin/env bash
# Trustee 1.2 fresh bootstrap/configuration. Existing independent KbsConfig needs a
# separately rehearsed migration; this entry point never adopts or deletes it.
# bootstrap: generated Restricted base + offline collateral, no workload resources.
# configure: publish approved policy/RVPS before attaching workload resources.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/release.sh
source "$REPO_ROOT/scripts/lib/release.sh"
load_release_defaults
NS="${NS:-trustee-operator-system}"
TRUSTEE_NAME="${TRUSTEE_NAME:-trustee-config}"
TRUSTEE_PROFILE="${TRUSTEE_PROFILE:-Restricted}"
TRUSTEE_CONTEXT="${TRUSTEE_CONTEXT:-}"
TEE="${TEE:-snp}"
ACTION="${1:-configure}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
HELPER="$REPO_ROOT/scripts/lib/trustee_config.py"
export NS TRUSTEE_NAME TRUSTEE_PROFILE

die() { echo "ERROR: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null || die "$1 is required"; }
oc() {
  if [[ -n "$TRUSTEE_CONTEXT" ]]; then command oc --context "$TRUSTEE_CONTEXT" --request-timeout="${OC_REQUEST_TIMEOUT:-30s}" "$@";
  else command oc --request-timeout="${OC_REQUEST_TIMEOUT:-30s}" "$@"; fi
}
cleanup() { [[ -z "${tmpdir:-}" ]] || rm -rf "$tmpdir"; }
trap cleanup EXIT
need python3
need jq
[[ "$ACTION" == bootstrap || "$ACTION" == configure ]] || die "usage: $0 [bootstrap|configure]"
[[ "$TEE" == snp ]] || die "this workflow targets AMD SEV-SNP; set TEE=snp"
# Rendering has no credential, kubeconfig, VCEK, or cluster dependency.
if [[ "${RENDER_ONLY:-0}" == 1 || "${RENDER_KBSCONFIG_ONLY:-0}" == 1 ]]; then
  python3 "$HELPER" render
  exit 0
fi
[[ "$TRUSTEE_VERSION" == 1.2.* ]] || die "this workflow requires a resolved Trustee 1.2 release"
[[ "$TRUSTEE_PROFILE" != Restricted || -n "$TRUSTEE_CONTEXT" ]] || die "set TRUSTEE_CONTEXT explicitly for the Restricted customer profile"
[[ "$TRUSTEE_PROFILE" != Permissive || "${TRUSTEE_LAB:-0}" == 1 ]] || die "Permissive requires TRUSTEE_LAB=1"
# Resolve artifact/schema identity BEFORE any cluster mutation.
require_resolved_release
need oc
umask 077
tmpdir="$(mktemp -d /tmp/coco-trustee.XXXXXX)"
python3 "$HELPER" render > "$tmpdir/trustee.json"
# Image build variables are not deployment inputs. Resources are attached only through
# explicit KBS_RESOURCE_NAMES after approved policy/reference validation.
oc whoami >/dev/null
actual_csv="$(oc -n "$NS" get csv "trustee-operator.v${TRUSTEE_VERSION}" -o json)"
jq -e '.status.phase == "Succeeded"' <<< "$actual_csv" >/dev/null || die "selected Trustee CSV is not Succeeded"

# Validate all local configuration before touching cluster state.
resources="${KBS_RESOURCE_NAMES:-}"
if [[ "$ACTION" == configure && "$TRUSTEE_PROFILE" == Restricted ]]; then
  [[ -s "${TRUSTEE_RESOURCE_POLICY_FILE:-}" ]] || die "configure requires TRUSTEE_RESOURCE_POLICY_FILE (approved resource-policy.rego)"
  [[ -s "${TRUSTEE_RVPS_FILE:-}" ]] || die "configure requires TRUSTEE_RVPS_FILE (validated target reference set)"
  [[ -n "$resources" ]] || die "configure requires explicit KBS_RESOURCE_NAMES; bootstrap attaches no customer resources"
  python3 "$HELPER" rvps --file "$TRUSTEE_RVPS_FILE" --namespace "$NS" > "$tmpdir/rvps.json"
  # A syntax/policy acceptance test is still required; block obvious permissive scaffolding here.
  grep -Eq 'default[[:space:]]+allow[[:space:]]*:?=[[:space:]]*false' "$TRUSTEE_RESOURCE_POLICY_FILE" || die "customer resource policy must default-deny"
fi
hwids="${HWIDS:-${HWID:-}}"
[[ -n "$hwids" ]] || die "set HWIDS to the approved offline collateral identities (space/comma separated)"
hwids="${hwids//,/ }"
hwids="$(printf '%s' "$hwids" | tr 'A-F' 'a-f')"
python3 "$HELPER" mounts --hwids "$hwids" > "$tmpdir/mounts.json"
# The collector/importer owns collateral Secrets. Check identities without reading values.
while IFS= read -r secret; do
  oc -n "$NS" get secret "$secret" -o name >/dev/null || die "missing collateral Secret $secret; collect/import it first"
done < <(jq -r '.[].secretName' "$tmpdir/mounts.json")
if [[ "$TRUSTEE_PROFILE" == Restricted ]]; then
  for secret in "${TRUSTEE_HTTPS_SECRET:-kbs-https-cert}" "${TRUSTEE_TOKEN_SECRET:-kbs-token-cert}"; do
    oc -n "$NS" get secret "$secret" -o name >/dev/null || die "required TLS Secret $secret must be provisioned out of band"
  done
fi

oc -n "$NS" get trusteeconfigs -o json > "$tmpdir/trustees.json"
oc -n "$NS" get kbsconfigs -o json > "$tmpdir/kbsconfigs.json"
count="$(jq '.items|length' "$tmpdir/trustees.json")"
if [[ "$count" == 0 ]]; then
  [[ "$(jq '.items|length' "$tmpdir/kbsconfigs.json")" == 0 ]] || die "independent KbsConfig detected; use the separately reviewed upgrade procedure"
  oc create --dry-run=server -f "$tmpdir/trustee.json" >/dev/null
  oc create -f "$tmpdir/trustee.json"
else
  [[ "$count" == 1 ]] || die "multiple TrusteeConfigs would compete for fixed deployment/service names"
  jq -e --arg n "$TRUSTEE_NAME" --arg p "$TRUSTEE_PROFILE" '.items[0] | .metadata.name == $n and .spec.profileType == $p' "$tmpdir/trustees.json" >/dev/null || die "existing TrusteeConfig identity/profile differs; refuse implicit ownership/profile change"
  if [[ "$TRUSTEE_PROFILE" == Restricted ]]; then
    jq -e --slurpfile desired "$tmpdir/trustee.json" '.items[0].spec | .httpsSpec.tlsSecretName == $desired[0].spec.httpsSpec.tlsSecretName and .attestationTokenVerificationSpec.tlsSecretName == $desired[0].spec.attestationTokenVerificationSpec.tlsSecretName' "$tmpdir/trustees.json" >/dev/null || die "existing TLS identities differ; refuse implicit certificate change"
  fi
  # Existing TC is operator/user-owned; do not reset its other settings on rerun.
  jq '.items[0]' "$tmpdir/trustees.json" > "$tmpdir/trustee-live.json"
  if [[ "$(jq '.items|length' "$tmpdir/kbsconfigs.json")" != 0 ]]; then
    jq -n --slurpfile t "$tmpdir/trustee-live.json" --slurpfile k "$tmpdir/kbsconfigs.json" '{trustee:$t[0],kbsconfigs:$k[0]}' | python3 "$HELPER" select >/dev/null
  fi
fi

wait_for() {
  local label="$1" deadline=$((SECONDS + WAIT_TIMEOUT)); shift
  until "$@"; do
    (( SECONDS < deadline )) || die "timed out: $label (no later configuration was applied)"
    sleep "$SLEEP_SECONDS"
  done
}
generated_ready() {
  oc -n "$NS" get trusteeconfig "$TRUSTEE_NAME" -o json > "$tmpdir/trustee-live.json" || return 1
  oc -n "$NS" get kbsconfigs -o json > "$tmpdir/kbsconfigs.json" || return 1
  jq -n --slurpfile t "$tmpdir/trustee-live.json" --slurpfile k "$tmpdir/kbsconfigs.json" '{trustee:$t[0],kbsconfigs:$k[0]}' | python3 "$HELPER" select > "$tmpdir/kbs.json" || return 1
  oc -n "$NS" get configmaps -o json > "$tmpdir/maps.json" || return 1
  jq -n --slurpfile t "$tmpdir/trustee-live.json" --slurpfile k "$tmpdir/kbs.json" --slurpfile m "$tmpdir/maps.json" '{trustee:$t[0],kbs:$k[0],maps:($m[0].items|map({key:.metadata.name,value:.})|from_entries)}' | python3 "$HELPER" ready >/dev/null
}
wait_for "generated resources and Operator migration markers" generated_ready
if [[ "$TRUSTEE_PROFILE" == Restricted ]]; then
  feature_args=(restricted --tee "$TEE")
  [[ "$ACTION" != configure ]] || feature_args+=(--file "$TRUSTEE_RVPS_FILE")
  jq -n --slurpfile t "$tmpdir/trustee-live.json" --slurpfile k "$tmpdir/kbs.json" --slurpfile m "$tmpdir/maps.json" \
    '{trustee:$t[0],kbs:$k[0],maps:($m[0].items|map({key:.metadata.name,value:.})|from_entries)}' | python3 "$HELPER" "${feature_args[@]}" >/dev/null
fi
kbs_name="$(jq -r '.metadata.name' "$tmpdir/kbs.json")"
config_cm="$(jq -r '.spec.kbsConfigMapName' "$tmpdir/kbs.json")"
resource_cm="$(jq -r '.spec.kbsResourcePolicyConfigMapName' "$tmpdir/kbs.json")"
rvps_cm="$(jq -r '.spec.kbsRvpsRefValuesConfigMapName' "$tmpdir/kbs.json")"
# Modify only the selected verifier setting; preserve unrelated TOML and all metadata.
oc -n "$NS" get cm "$config_cm" -o json | python3 "$HELPER" offline-config --tee "$TEE" > "$tmpdir/config-patch.json"
oc -n "$NS" patch cm "$config_cm" --type=merge --patch-file "$tmpdir/config-patch.json"

if [[ "$ACTION" == configure && "$TRUSTEE_PROFILE" == Restricted ]]; then
  oc -n "$NS" get cm "$rvps_cm" -o json > "$tmpdir/rvps-live.json"
  jq -n --slurpfile c "$tmpdir/rvps-live.json" --slurpfile r "$tmpdir/rvps.json" '{metadata:{resourceVersion:$c[0].metadata.resourceVersion},data:$r[0].data}' > "$tmpdir/rvps-patch.json"
  oc -n "$NS" patch cm "$rvps_cm" --type=merge --patch-file "$tmpdir/rvps-patch.json"
  rv="$(oc -n "$NS" get cm "$resource_cm" -o jsonpath='{.metadata.resourceVersion}')"
  jq -n --arg rv "$rv" --rawfile policy "$TRUSTEE_RESOURCE_POLICY_FILE" '{metadata:{resourceVersion:$rv},data:{"resource-policy.rego":$policy}}' > "$tmpdir/policy-patch.json"
  oc -n "$NS" patch cm "$resource_cm" --type=merge --patch-file "$tmpdir/policy-patch.json"
fi
if [[ "$ACTION" == configure && "$TRUSTEE_PROFILE" == Permissive ]]; then
  # This seeder is intentionally unavailable to the customer profile.
  NS="$NS" TRUSTEE_CONTEXT="$TRUSTEE_CONTEXT" TRUSTEE_PROFILE=Permissive TRUSTEE_LAB=1 HWIDS="$hwids" bash "$REPO_ROOT/scripts/seed-trustee-secrets.sh"
  resources="${resources:-regcred attestation-cert attestation-status sample credential security-policy registry-configuration}"
  [[ -z "${RUNG_SIGNED_COSIGN_PUB:-}" ]] || resources="$resources sig-public-key"
fi
if [[ "$ACTION" == bootstrap ]]; then resources=""; fi
for secret in ${resources//,/ }; do
  oc -n "$NS" get secret "$secret" -o name >/dev/null || die "resource Secret $secret is absent"
done
oc -n "$NS" get kbsconfig "$kbs_name" -o json | python3 "$HELPER" kbs-patch --tee "$TEE" --hwids "$hwids" --resources "$resources" > "$tmpdir/kbs-patch.json"
oc -n "$NS" patch kbsconfig "$kbs_name" --type=merge --patch-file "$tmpdir/kbs-patch.json"
# Converter-backed resource Secret refresh requires a new serving pod; do not infer
# reload from an event. Watch the new UID as well as the deployment's revision.
oc -n "$NS" get pods -l app=kbs -o json | jq '[.items[].metadata.uid]' > "$tmpdir/old-uids.json"
oc -n "$NS" rollout restart deployment/trustee-deployment
serving_ready() {
  oc -n "$NS" get deployment trustee-deployment -o json > "$tmpdir/deployment.json" || return 1
  oc -n "$NS" get pods -l app=kbs -o json > "$tmpdir/pods.json" || return 1
  # Re-read live references and versions; a Ready pod alone may still serve old subPath data.
  generated_ready || return 1
  jq -n --slurpfile k "$tmpdir/kbs.json" --slurpfile m "$tmpdir/maps.json" \
    --slurpfile d "$tmpdir/deployment.json" --slurpfile p "$tmpdir/pods.json" --slurpfile u "$tmpdir/old-uids.json" \
    '{kbs:$k[0],maps:($m[0].items|map({key:.metadata.name,value:.})|from_entries),deployment:$d[0],pods:$p[0],old_uids:$u[0]}' | python3 "$HELPER" serving >/dev/null
}
wait_for "new Trustee serving pod" serving_ready
# Recheck migration/ownership after all updates. Hardware allow/deny tests remain separate.
generated_ready || die "generated resource ownership changed during configuration"
echo "Trustee $ACTION complete: profile=$TRUSTEE_PROFILE context=${TRUSTEE_CONTEXT:-current} name=$TRUSTEE_NAME"
[[ "$ACTION" != bootstrap ]] || echo "Next: freeze workload initdata, generate references, then configure approved policy and resources."
