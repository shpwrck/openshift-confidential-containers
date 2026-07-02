#!/usr/bin/env bash
# =============================================================================================
# Mint the three ARTIFACTORY in-guest-pull KBS resources: credential, security-policy,
# registry-configuration. These are the Artifactory-specific translations of the resources that
# scripts/seed-trustee-secrets.sh creates for the rig mirror.
#
# TWO WAYS to use this bundle:
#   (A) FAST — reuse the existing rig script for everything EXCEPT the registries.conf remap:
#         MIRROR_REGISTRY=artifactory.corp:443 \
#         MIRROR_USERNAME=<svc-account> \
#         MIRROR_PASSWORD_FILE=/path/to/artifactory-token \
#         MIRROR_CA=/path/to/artifactory-ca.pem \
#         HWIDS=<hwid1[,hwid2...]> \
#         scripts/seed-trustee-secrets.sh
#       That gets you credential + security-policy + VCEK + the out-of-band secrets correctly keyed
#       to Artifactory. THEN replace the registry-configuration Secret with your hand-authored remap
#       (registries.conf.artifactory.example), because the script hard-codes rig repo paths:
#         oc -n trustee-operator-system create secret generic registry-configuration \
#           --from-file=test=registries.conf.artifactory.filled --dry-run=client -o yaml | oc apply -f -
#
#   (B) STANDALONE — if you can't run the rig script, this script mints just the three image-pull
#       resources from the placeholders below. (You still need the out-of-band secrets + VCEK +
#       RVPS from Phase 5 — see the repo scripts.)
# =============================================================================================
set -euo pipefail

NS="${NS:-trustee-operator-system}"

# --- FILL THESE ------------------------------------------------------------------------------
ARTIFACTORY="${ARTIFACTORY:?set ARTIFACTORY=host:port exactly as it appears in your image refs, e.g. artifactory.corp:443}"
# Registry creds — provide EITHER (1) an existing dockerconfig, OR (2) user + password file:
#   (1) DOCKERCONFIG_JSON=<path> — reuse an existing docker config.json, or your OpenShift pull
#       secret extracted with:
#         oc get secret pull-secret -n openshift-config \
#           -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > dockerconfig.json
#       The script keeps ONLY the entry whose key == $ARTIFACTORY (so other registries' creds don't
#       leak into the guest) and re-keys it to `test` (dotless) for KBS serving.
#   (2) ARTIFACTORY_USER + ARTIFACTORY_PASSWORD_FILE — build the auth from scratch.
DOCKERCONFIG_JSON="${DOCKERCONFIG_JSON:-}"
ARTIFACTORY_USER="${ARTIFACTORY_USER:-}"
ARTIFACTORY_PASSWORD_FILE="${ARTIFACTORY_PASSWORD_FILE:-}"
# Path to your hand-authored registries.conf (from registries.conf.artifactory.example, filled in):
REGISTRIES_CONF="${REGISTRIES_CONF:?set REGISTRIES_CONF=path to your filled registries.conf}"
# ---------------------------------------------------------------------------------------------

command -v oc  >/dev/null || { echo "oc not on PATH" >&2; exit 2; }
command -v jq  >/dev/null || { echo "jq not on PATH" >&2; exit 2; }
oc whoami >/dev/null 2>&1 || { echo "oc is not logged into a cluster" >&2; exit 2; }
[[ -r "$REGISTRIES_CONF" ]] || { echo "cannot read $REGISTRIES_CONF" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1) credential — docker auths JSON, keyed by the ARTIFACTORY host:port (the mirror location image-rs
#    authenticates against), NOT the upstream registry. Served at kbs:///default/credential/test.
if [[ -n "$DOCKERCONFIG_JSON" ]]; then
  [[ -r "$DOCKERCONFIG_JSON" ]] || { echo "cannot read $DOCKERCONFIG_JSON" >&2; exit 2; }
  # Accept a full docker config ({"auths":{...}}) or a bare auths map; keep ONLY the $ARTIFACTORY entry.
  entry="$(jq -ec --arg reg "$ARTIFACTORY" '(.auths // .)[$reg]' "$DOCKERCONFIG_JSON")" \
    || { echo "no auth entry for '$ARTIFACTORY' in $DOCKERCONFIG_JSON — the key must match the host:port in your image refs" >&2; exit 2; }
  jq -e 'has("auth")' <<<"$entry" >/dev/null \
    || echo "WARN: the '$ARTIFACTORY' entry has no inline \"auth\" — credHelpers/identitytoken are NOT usable in-guest" >&2
  jq -nc --arg reg "$ARTIFACTORY" --argjson entry "$entry" '{auths: {($reg): $entry}}' > "$tmp/credential.json"
elif [[ -n "$ARTIFACTORY_USER" && -n "$ARTIFACTORY_PASSWORD_FILE" ]]; then
  [[ -r "$ARTIFACTORY_PASSWORD_FILE" ]] || { echo "cannot read $ARTIFACTORY_PASSWORD_FILE" >&2; exit 2; }
  pass="$(tr -d '\n' < "$ARTIFACTORY_PASSWORD_FILE")"
  auth="$(printf '%s' "${ARTIFACTORY_USER}:${pass}" | base64 -w0)"
  jq -nc --arg reg "$ARTIFACTORY" --arg auth "$auth" '{auths: {($reg): {auth: $auth}}}' > "$tmp/credential.json"
else
  echo "provide DOCKERCONFIG_JSON, or ARTIFACTORY_USER + ARTIFACTORY_PASSWORD_FILE" >&2; exit 2
fi

# 2) security-policy — MUST include a `transports` block (a bare `default` fails "Invalid image policy
#    file"). Permissive form keyed by the Artifactory host. Served at kbs:///default/security-policy/test.
jq -nc --arg reg "$ARTIFACTORY" \
  '{default: [{type: "insecureAcceptAnything"}],
    transports: {docker: {($reg): [{type: "insecureAcceptAnything"}]}}}' > "$tmp/security-policy.json"

# 3) registry-configuration — your hand-authored registries.conf remap. Served at
#    kbs:///default/registry-configuration/test.
cp "$REGISTRIES_CONF" "$tmp/registries.conf"

oc -n "$NS" create secret generic credential \
  --from-file=test="$tmp/credential.json" --dry-run=client -o yaml | oc apply -f -
oc -n "$NS" create secret generic security-policy \
  --from-file=test="$tmp/security-policy.json" --dry-run=client -o yaml | oc apply -f -
oc -n "$NS" create secret generic registry-configuration \
  --from-file=test="$tmp/registries.conf" --dry-run=client -o yaml | oc apply -f -

echo "Seeded credential, security-policy, registry-configuration in $NS (Artifactory: $ARTIFACTORY)"
echo "NOTE: these Secret names must be listed in KbsConfig.spec.kbsSecretResources (they already are"
echo "      in gitops/base/trustee/kbsconfig.yaml). Create them BEFORE deploying Trustee, or KBS"
echo "      crash-loops in a way that looks like an attestation failure."
