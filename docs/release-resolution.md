# Resolve release artifact identities

**Status: authenticated artifact resolution executed on 2026-10-05.** The immutable OCP 4.20 catalog validated, the five selected bundles matched their catalog records, and all 25 unique advertised related-image identities plus four helper/diagnostic identities resolved. The external candidate BOM and ImageSet passed `verify-release.py --require-resolved`. An authenticated oc-mirror v2 dry run passed and planned 220 images; all 28 unique operator/related/helper sources were present. Its fresh cache lacked all 220 images, so actual image transfer remains pending. The reviewed inventory is adopted in the tracked release manifest and ImageSet; no cluster installation or hardware validation is established by these checks. The commands below remain a repeatable procedure, not substitute evidence for another run.

Use this before [provisioning and validation](latitude-validation.md). It reads registries and writes local evidence. It does not deploy, push images, approve InstallPlans or establish hardware compatibility. The inputs are the [release manifest](../install/release-manifest.json) and [ImageSet](../install/imageset-config.yaml).

## Prerequisites and external paths

Use the Linux controller described in the [quickstart](current-quickstart.md), with Bash, Python, PyYAML, `jq`, `oc`, the oc-mirror v2 plugin, `skopeo` and `opm` on `PATH`. The execution controller used Skopeo 1.24.1 and the checksum-verified opm binary distributed with OCP 4.20.39. Install these tools on another controller before running the procedure.

- Install Skopeo using its [official distribution-package instructions](https://github.com/containers/skopeo/blob/main/install.md). For Fedora/RHEL the command is `sudo dnf install skopeo`; use the documented package command for other distributions.
- Obtain opm for the controller's operating system from the Red Hat downloads linked by [Installing the opm CLI](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/cli_tools/opm-cli). Verify the downloaded archive against its published checksum before extracting and adding the binary to `PATH`.
- Prepare oc/oc-mirror using [the repository tool installer](../scripts/install-tools.sh) and the selected release. The [OCP 4.20 oc-mirror v2 guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2) documents the supported workflow.

Run the following blocks in the same Bash session, from the checkout root. Set `AUTH_FILE` to an existing external Red Hat pull-secret file. The example below uses the external Linux credential directory; adapt the path on another controller. Never print or copy the authentication file into the evidence or checkout, and do not enable shell tracing.

```bash
set -euo pipefail
umask 077
AUTH_FILE="$HOME/.local/state/openshift-confidential-containers/credentials/pull-secret.json"
COCO_STATE_DIR="${COCO_STATE_DIR:-$HOME/.local/state/openshift-confidential-containers}"
OUT="$COCO_STATE_DIR/release-resolution-$(date -u +%Y%m%dT%H%M%SZ)"
export AUTH_FILE OUT
python3 - <<'PY'
import os
from pathlib import Path
repo = Path.cwd().resolve()
for name in ("AUTH_FILE", "OUT"):
    path = Path(os.environ[name]).expanduser().resolve()
    if path == repo or repo in path.parents or str(path).lower() == "/mnt/c/homelab" or str(path).lower().startswith("/mnt/c/homelab/"):
        raise SystemExit(f"{name} must be outside the checkout and Homelab")
if not Path(os.environ["AUTH_FILE"]).is_file():
    raise SystemExit("Supply the external pull-secret file before continuing")
PY
for tool in jq oc skopeo opm; do command -v "$tool" >/dev/null; done
mkdir -p "$OUT/catalog" "$OUT/bundles" "$OUT/images"
cp install/release-manifest.json "$OUT/release-manifest.input.json"
cp install/imageset-config.yaml "$OUT/imageset-config.input.yaml"
sha256sum "$OUT/release-manifest.input.json" "$OUT/imageset-config.input.yaml" > "$OUT/input-sha256.txt"
git rev-parse HEAD > "$OUT/checkout.txt"
date -u +%FT%TZ > "$OUT/started-at.txt"
skopeo --version > "$OUT/skopeo-version.txt"
opm version > "$OUT/opm-version.txt"
oc mirror version --v2 > "$OUT/oc-mirror-version.txt"
```

## Capture immutable registry identities

The helper below saves the raw manifest, computes its digest and fetches it again by that digest. Both byte comparison and digest comparison must succeed. It accepts explicit tags or SHA-256 references, retains the original reference, and never changes a repository file. Authentication/TLS failures are failures, not permission to use guessed identities. [Skopeo inspect](https://github.com/containers/skopeo/blob/main/docs/skopeo-inspect.1.md) and [manifest-digest](https://github.com/containers/skopeo/blob/main/docs/skopeo-manifest-digest.1.md) describe these commands.

```bash
capture_image() {
  local ref="$1" directory="$2" repository expected="" digest
  case "$ref" in
    *@sha256:*) repository="${ref%@*}"; expected="${ref##*@}" ;;
    *@*) echo "Unsupported image digest: $ref" >&2; return 1 ;;
    *)
      [[ "${ref##*/}" == *:* ]] || { echo "Explicit image tag required: $ref" >&2; return 1; }
      repository="${ref%:*}"
      ;;
  esac
  mkdir -p "$directory"
  printf '%s\n' "$ref" > "$directory/source-ref.txt"
  skopeo inspect --authfile "$AUTH_FILE" --tls-verify=true --raw \
    "docker://$ref" > "$directory/manifest.json"
  digest="$(skopeo manifest-digest "$directory/manifest.json")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  [[ -z "$expected" || "$digest" == "$expected" ]]
  skopeo inspect --authfile "$AUTH_FILE" --tls-verify=true --raw \
    "docker://${repository}@${digest}" > "$directory/manifest-by-digest.json"
  cmp "$directory/manifest.json" "$directory/manifest-by-digest.json"
  [[ "$(skopeo manifest-digest "$directory/manifest-by-digest.json")" == "$digest" ]]
  printf '%s@%s\n' "$repository" "$digest" > "$directory/ref.txt"
}

CATALOG_REF="$(jq -er '.catalog.ref' "$OUT/release-manifest.input.json")"
capture_image "$CATALOG_REF" "$OUT/catalog-image"
CATALOG_PIN="$(cat "$OUT/catalog-image/ref.txt")"
CATALOG_REPOSITORY="${CATALOG_PIN%@*}"
CATALOG_DIGEST="${CATALOG_PIN##*@}"
```

An index digest and its architecture-specific manifest digest are different identities. Keep the top-level pin for the BOM and ImageSet. For rendering, select and separately verify the catalog's Linux/AMD64 manifest; this avoids depending on the controller's architecture. Do not reserialize a raw manifest before hashing it.

```bash
CATALOG_AMD64_DIGEST="$(jq -er --arg digest "$CATALOG_DIGEST" '
  if has("manifests") then
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")]
    | if length == 1 then .[0].digest else error("expected exactly one Linux/AMD64 catalog manifest") end
  else $digest end
' "$OUT/catalog-image/manifest.json")"
capture_image "$CATALOG_REPOSITORY@$CATALOG_AMD64_DIGEST" "$OUT/catalog-amd64"
CATALOG_RENDER_PIN="$(cat "$OUT/catalog-amd64/ref.txt")"
skopeo --override-os linux --override-arch amd64 inspect --no-tags \
  --authfile "$AUTH_FILE" --tls-verify=true "docker://$CATALOG_RENDER_PIN" > "$OUT/catalog-amd64/inspect.json"
jq -e '.Os == "linux" and .Architecture == "amd64"' "$OUT/catalog-amd64/inspect.json" >/dev/null
# This opm build reads Docker's config.json; REGISTRY_AUTH_FILE alone did not work.
# Reference the existing secret from a separate external credential directory.
export DOCKER_CONFIG="$(dirname "$AUTH_FILE")/opm-config"
python3 - <<'PYAUTH'
import os
from pathlib import Path
config = Path(os.environ["DOCKER_CONFIG"])
config.mkdir(mode=0o700, exist_ok=True)
target = Path(os.environ["AUTH_FILE"]).resolve()
link = config / "config.json"
if not link.exists() and not link.is_symlink():
    link.symlink_to(target)
if link.resolve() != target:
    raise SystemExit("Existing Docker config does not reference the selected auth file")
PYAUTH
REGISTRY_AUTH_FILE="$AUTH_FILE" opm render "$CATALOG_RENDER_PIN" -o json > "$OUT/catalog/catalog.jsonl"
opm validate "$OUT/catalog"
```

Only the digest-pinned catalog is rendered. Preserve its complete JSON stream for channel and dependency review. The OCP 4.20.39 opm binary used in this run required `DOCKER_CONFIG/config.json`; `REGISTRY_AUTH_FILE` alone failed although Skopeo could authenticate. Keep both variables set for the remaining opm commands. The symlink above stays beside the original credential, outside evidence and the checkout, and does not copy its contents. Credential lookup varies by opm build; its [registry implementation](https://github.com/operator-framework/operator-registry/blob/master/pkg/image/containersimageregistry/registry.go) is the upstream reference. Neither the auth file nor a token belongs in captured commands or output.

## Select exact package/channel/CSV/version tuples

Create a selection worksheet from the proposed BOM. OSC and Trustee entries are **candidates to check**. NFD, cert-manager and Gatekeeper start unresolved; fill their CSV and version from the captured catalog, without choosing a version merely because it sorts highest.

```bash
jq '[.operators | to_entries[] | {
  key: .key, package: .value.package, channel: .value.channel,
  csv: .value.startingCSV, version: .value.version
}]' "$OUT/release-manifest.input.json" > "$OUT/selections.json"

while IFS=$'\t' read -r key package channel; do
  jq -s --arg package "$package" --arg channel "$channel" '
    . as $all
    | [$all[] | select(.schema == "olm.channel" and .package == $package and .name == $channel)
       | .entries[].name] as $members
    | [$all[] | select(.schema == "olm.bundle" and .package == $package)
       | select(.name as $name | $members | index($name))
       | {csv:.name, version:(.properties[] | select(.type == "olm.package") | .value.version), image:.image}]
  ' "$OUT/catalog/catalog.jsonl" > "$OUT/${key}-available.json"
done < <(jq -r '.[] | [.key,.package,.channel] | @tsv' "$OUT/selections.json")
```

Review the five `*-available.json` files, then edit `selections.json`. The actual version comes from the bundle's `olm.package` property, not from parsing its CSV name. If a proposed OSC/Trustee tuple is absent, stop and review the product target; do not substitute another release silently. Red Hat documents these [catalog queries](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/extensions/cluster-extensions); the [FBC schema](https://olm.operatorframework.io/docs/reference/file-based-catalogs/) defines channel entries and bundle properties.

The following check requires exactly one matching channel entry and one bundle with the selected package, CSV and version. It produces the records used for subsequent inspection:

```bash
jq -se --slurpfile selections "$OUT/selections.json" '
  . as $all | [ $selections[0][] as $s
    | if ([$s.key,$s.package,$s.channel,$s.csv,$s.version] | all(type == "string" and length > 0))
      then $s else error("incomplete selection") end
    | [$all[] | select(.schema == "olm.channel" and .package == $s.package and .name == $s.channel)
       | .entries[] | select(.name == $s.csv)] as $entries
    | [$all[] | select(.schema == "olm.bundle" and .package == $s.package and .name == $s.csv)
       | select(any(.properties[]?; .type == "olm.package"
           and .value.packageName == $s.package and .value.version == $s.version))] as $bundles
    | if ($entries|length) == 1 and ($bundles|length) == 1
      then {selection:$s, bundle:$bundles[0]} else error("selection absent or ambiguous: " + $s.key) end
  ]
' "$OUT/catalog/catalog.jsonl" > "$OUT/selected-bundles.json"

while IFS=$'\t' read -r key image; do
  capture_image "$image" "$OUT/bundles/$key"
  pin="$(cat "$OUT/bundles/$key/ref.txt")"
  REGISTRY_AUTH_FILE="$AUTH_FILE" opm render "$pin" -o json > "$OUT/bundles/$key/rendered.jsonl"
done < <(jq -r '.[] | [.selection.key,.bundle.image] | @tsv' "$OUT/selected-bundles.json")
```

Compare each independently rendered bundle with its catalog record: package, CSV, version, advertised related-image references and dependency properties must agree. Catalog `olm.csv.metadata` and rendered-bundle `olm.bundle.object` are different representations; decode the latter objects and inspect the contained CSV, instead of requiring these representation properties to be byte-identical. Compare all other properties as unordered sets. The contained CSV name/version and any required CRDs/APIs must agree with the selection and dependency review. A bundle using a multi-architecture index needs the same child-manifest selection check as the catalog. Keep the top-level bundle identity as well as the selected child. A discrepancy stops resolution; catalog metadata alone is not evidence that the referenced bundle contains those contents.

## Inspect dependencies and resolve related images

Inspect dependency properties and catalog deprecation notices:

```bash
jq '[.[] | {selection, requirements:[.bundle.properties[]?
  | select(.type == "olm.package.required" or .type == "olm.gvk.required" or .type == "olm.constraint")]}]' \
  "$OUT/selected-bundles.json" > "$OUT/dependency-requirements.json"
jq -s '[.[] | select(.schema == "olm.deprecations")]' "$OUT/catalog/catalog.jsonl" > "$OUT/deprecations.json"
jq -r '.[].bundle.relatedImages[]?.image' "$OUT/selected-bundles.json" | sort -u > "$OUT/related-images.txt"
jq -r '.images[].ref' "$OUT/release-manifest.input.json" > "$OUT/helper-images.txt"
cat "$OUT/related-images.txt" "$OUT/helper-images.txt" | sort -u > "$OUT/images-to-resolve.txt"

number=0
while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  number=$((number + 1))
  capture_image "$image" "$OUT/images/$number"
done < "$OUT/images-to-resolve.txt"
```

Retain every advertised related image, even if its purpose is outside this AMD workload. Record architecture metadata separately; do not relabel a non-AMD64 image or discard it to obtain a passing inventory. Check Linux/AMD64 support for the images actually used by this deployment. If a helper-image candidate tag does not exist, obtain the correct reference from the corresponding product documentation/catalog and record that explicit selection before retrying.

For each required package/version range, GVK or constraint, record the selected provider bundle and why it satisfies the requirement. If a provider is outside the five selected packages, stop and extend the reviewed dependency set, BOM and ImageSet. Record exact additional dependency CSVs for the existing InstallPlan checks; do not guess them from an error or disable the approval check.

**oc-mirror v2 does not infer operator/GVK dependencies.** Explicitly include required dependent packages and versions. If the chosen channel differs from `olm.package.defaultChannel`, set the ImageSet package's `defaultChannel` to the selected included channel. Preserve the original default channel in evidence. These rules and the exact-version filtering limits are documented under [operator filtering and ImageSet parameters](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2).

## Synchronize the proposed configuration and verify it

Copy the inputs to external candidate files, then edit them using the captured evidence:

```bash
cp "$OUT/release-manifest.input.json" "$OUT/release-manifest.resolved.json"
cp "$OUT/imageset-config.input.yaml" "$OUT/imageset-config.resolved.yaml"
```

Keep these values consistent:

| File | Required updates |
|---|---|
| `release-manifest.resolved.json` | Catalog `ref` and `digest`; every operator's package/channel/version/startingCSV, immutable `bundleImage` and complete immutable `relatedImages`; all helper-image refs. Add evidence paths/hashes and resolution date. |
| `imageset-config.resolved.yaml` | Same catalog and helper refs; each selected operator's channel and exact `minVersion == maxVersion`; explicit dependencies and `defaultChannel` where needed. |
| [Operator Subscriptions](../gitops/base/operators/subscriptions.yaml) and [Gatekeeper Subscription](../gitops/base/gatekeeper/operator.yaml) | Same package/channel/source and explicit `startingCSV` for every selected operator; retain `installPlanApproval: Manual`. Stage these edits for review alongside the proposed BOM. |

Mark an identity `resolution: verified` only after its registry checks and metadata comparison succeed. Leave `hardwareValidated`, `compatibilityValidated` and `upgradePathVerified` unchanged. Save a short `resolution-notes.md` in the evidence directory identifying selections, dependency decisions and any unresolved failures. Hash the captured files after the work is complete; do not hash or copy the auth file into that record.

Review the local configuration before any real mirror operation:

```bash
(
  cd "$OUT"  # oc-mirror can also write a log in the current directory.
  env -u REGISTRY_AUTH_FILE oc mirror --authfile "$AUTH_FILE" \
    --cache-dir "$OUT/mirror-cache" \
    -c "$OUT/imageset-config.resolved.yaml" \
    "file://$OUT/mirror-preview" --dry-run --v2
)

IMAGESET_CONFIG="$OUT/imageset-config.resolved.yaml" \
python3 scripts/verify-release.py \
  --manifest "$OUT/release-manifest.resolved.json" --require-resolved
```

Use `--authfile` for this command and unset `REGISTRY_AUTH_FILE`: the tested oc-mirror v2 build interprets that environment variable as configuration for its embedded registry and fails. Its destination path also rejects the literal component `dry-run`; `mirror-preview` avoids that reserved name.

Inspect the dry-run mapping under `mirror-preview/working-dir/dry-run/` against the selected bundle/image inventory. Missing cache entries before the first mirror are expected; a missing required image in the planned mapping is not. Resolve graph/default-channel errors by reviewing the selection rather than widening the version range automatically. A dry run does not prove successful mirroring. [Red Hat's dry-run procedure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2) describes its outputs and limits.

The existing verifier reads static Subscriptions from the checkout, so review their matching edits before running the candidate check above. It checks agreement and required resolution fields; it does not independently reproduce registry verification or validate dependency satisfiability.

After reviewing the non-secret candidate diff and evidence, update the checked-in BOM and ImageSet together:

```bash
cp "$OUT/release-manifest.resolved.json" install/release-manifest.json
cp "$OUT/imageset-config.resolved.yaml" install/imageset-config.yaml
git diff -- install/release-manifest.json install/imageset-config.yaml \
  gitops/base/operators/subscriptions.yaml gitops/base/gatekeeper/operator.yaml
python3 scripts/verify-release.py --require-resolved
```

The later real mirror run must also produce the intended CatalogSource name/image; reconcile the generated resource with the BOM and Subscriptions before installation. Continue through the [quickstart](current-quickstart.md) only after unresolved identities are cleared. Keep the evidence and the final BOM hash with the validation run; successful artifact resolution remains separate from cluster, attestation and workload-policy proof.

## Authenticated selection recorded on 2026-10-05

The external evidence run `release-resolution/20261005T135203Z` contains the complete pinned catalog, bundle manifests and decoded CSVs, raw registry manifests, architecture metadata, comparisons and candidate configuration. Its `verify-release.txt` records a successful strict check. The [portable resolution record](validation/release-resolution-2026-10-05.json) preserves immutable references, counts, hashes, check outcomes and limits. Retain raw evidence with the controller state; do not copy credentials into the repository.

| Package | Channel | Selected version | Exact CSV |
| --- | --- | --- | --- |
| sandboxed-containers-operator | stable | 1.13.1 | sandboxed-containers-operator.v1.13.1 |
| trustee-operator | stable | 1.2.1 | trustee-operator.v1.2.1 |
| nfd | stable | 4.20.0-202609201357 | nfd.4.20.0-202609201357 |
| openshift-cert-manager-operator | stable-v1 | 1.20.1 | cert-manager-operator.v1.20.1 |
| gatekeeper-operator-product | stable | 3.21.1 | gatekeeper-operator-product.v3.21.1 |

NFD is the OCP-aligned 4.20 stable head. The selected cert-manager and Gatekeeper bundles are their catalog channel heads; the [Red Hat operator lifecycle matrix](https://access.redhat.com/support/policy/updates/openshift_operators) lists cert-manager 1.20 and Gatekeeper 3.21 as supported on OCP 4.20 and in full support on the resolution date. All five selected channels are also their packages' default channels. None of these bundles declares an additional required package, GVK or constraint, or a required CRD/API in its CSV. This does not remove application prerequisites such as NFD or cert-manager.

Gatekeeper's CSV identifies OpenShift Platform Plus or Red Hat Advanced Cluster Management as valid subscriptions. Successful registry access proves artifact accessibility, not this support entitlement. Confirm the applicable subscription separately.

The OSC must-gather tag `1.13.1` resolves to the same image advertised by its operator bundle; the image's version label is `1.13`. The documented Trustee must-gather `1.2` tag resolves successfully, with image version label `1.2.0`. Those image labels are recorded as observed and are not relabeled as the operator's patch version.
