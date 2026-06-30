#!/usr/bin/env bash
# Render restrictive Trustee policies for the rung-b measured-initdata gate.
set -euo pipefail

NS="${NS:-trustee-operator-system}"
RUNG_B_KEY_ID="${RUNG_B_KEY_ID:-kbs:///default/image-key/rung-b}"

die() {
	echo "ERROR: $*" >&2
	exit 2
}

need() {
	command -v "$1" >/dev/null || die "$1 is not on PATH"
}

kbs_uri_resource_path() {
	local uri="$1" path
	if [[ "$uri" != kbs:///* ]]; then
		die "KBS URI must start with kbs:///: $uri"
	fi
	path="${uri#kbs:///}"
	[[ -n "$path" && "$path" != /* ]] || die "KBS URI has no resource path: $uri"
	printf '%s\n' "$path"
}

rego_array_for_path() {
	local path="$1" part
	local -a parts
	IFS=/ read -r -a parts <<< "$path"
	for part in "${parts[@]}"; do
		[[ -n "$part" ]] || die "KBS URI contains an empty path component: $path"
	done
	printf '%s\n' "${parts[@]}" | jq -R . | jq -s -c .
}

render() {
	local initdata_file="$1" key_path key_path_rego initdata_sha256

	[[ -f "$initdata_file" ]] || die "initdata file not found: $initdata_file"
	need jq

	# Reject ANY unresolved __PLACEHOLDER__ (__KBS_URL__, __TRUSTEE_CA_PEM__, __MIRROR_CA_PEM__, …).
	# The earlier guard listed only two and missed __MIRROR_CA_PEM__ that the example initdata carries.
	if grep -Eq '__[A-Z][A-Z0-9_]*__' "$initdata_file"; then
		die "$initdata_file still has unresolved initdata placeholders (__...__)"
	fi
	# Allow an optional trailing TOML inline comment after the algorithm line (the example file has one).
	if ! grep -Eq '^algorithm[[:space:]]*=[[:space:]]*"sha256"[[:space:]]*(#.*)?$' "$initdata_file"; then
		die "$initdata_file must declare algorithm = \"sha256\" for this SNP HOST_DATA policy renderer"
	fi

	# CAVEAT (verify on the rung-b path — currently upstream-blocked): this is the sha256 of the
	# initdata FILE as-is. The policy below gates the image key on the attestation report's init_data
	# matching this digest, so it is correct ONLY if OSC measures these same bytes into init_data /
	# HOST_DATA. If OSC measures a different encoding (e.g. the gzip+base64 annotation value, or a
	# canonicalized form), the digest never matches and the key is silently withheld. Confirm against
	# a real rung-b attestation report before relying on this.
	initdata_sha256="$(sha256sum "$initdata_file" | awk '{print $1}')"
	key_path="$(kbs_uri_resource_path "$RUNG_B_KEY_ID")"
	key_path_rego="$(rego_array_for_path "$key_path")"

	cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: attestation-policy
  namespace: ${NS}
data:
  default_cpu.rego: |
    package policy

    import rego.v1

    # AR4SI (RATS EAR) trustworthiness tiers: 2 = "Affirming" (claim verified/trusted); higher
    # tiers (32+, e.g. 36) are "Warning"/not-affirmed. The image key is released (resource-policy
    # below) only when 'configuration' is 2 — which happens ONLY if the measured init_data matches
    # our digest. The 36 default keeps 'configuration' un-affirmed until that match, so a measured-
    # initdata mismatch leaves it at 36 and the key is withheld. Other claims default to 2 (affirmed).
    default hardware := 2
    default executables := 2
    default configuration := 36
    default file_system := 2
    default instance_identity := 2
    default runtime_opaque := 2
    default storage_opaque := 2
    default sourced_data := 2

    configuration := 2 if {
      input.init_data == "${initdata_sha256}"
    }

    trust_claims := {
      "executables": executables,
      "hardware": hardware,
      "configuration": configuration,
      "file-system": file_system,
      "instance-identity": instance_identity,
      "runtime-opaque": runtime_opaque,
      "storage-opaque": storage_opaque,
      "sourced-data": sourced_data,
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-policy
  namespace: ${NS}
data:
  policy.rego: |
    package policy

    import rego.v1

    default allow := false

    image_key_path := ${key_path_rego}

    image_key_request if {
      data.plugin == "resource"
      data["resource-path"] == image_key_path
    }

    allow if {
      data.plugin == "resource"
      not image_key_request
    }

    allow if {
      image_key_request
      some sm
      input["submods"][sm]["ear.trustworthiness-vector"]["configuration"] == 2
    }
YAML
}

usage() {
	cat >&2 <<'EOF'
usage: render-rung-b-measurement-policy.sh <rendered-initdata.toml>

Renders two ConfigMaps:
  - attestation-policy: affirms configuration only when input.init_data equals
    the SHA-256 HOST_DATA value for the provided initdata TOML.
  - resource-policy: releases only the RUNG_B_KEY_ID resource when the EAR
    trustworthiness-vector configuration claim is affirming.

Environment:
  NS              Trustee namespace (default: trustee-operator-system)
  RUNG_B_KEY_ID   KBS URI for the encrypted-image key
EOF
}

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
	"")
		usage
		exit 2
		;;
	*)
		render "$1"
		;;
esac
