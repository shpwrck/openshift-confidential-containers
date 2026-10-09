# Resolve a release set

The [manifest](../install/release-manifest.json) is the source of selected versions
and immutable identities. The checked-in set was resolved with authenticated
registry access on **October 5, 2026**; [the receipt](validation/release-resolution-2026-10-05.json)
records the catalog, five bundles, related/helper images and dry-run outcome.
The later [hardware results](validation/README.md) are separate evidence.

Use this process when changing versions. Resolution reads registries and writes
protected external evidence; it does not approve an upgrade or validate hardware.

## Tools and evidence

Use a connected Linux controller with Python/PyYAML, `jq`, the selected `oc` and
oc-mirror v2, Skopeo and opm. Obtain Skopeo through its
[distribution package instructions](https://github.com/containers/skopeo/blob/main/install.md)
and opm through [Red Hat's CLI guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/cli_tools/opm-cli).
Verify downloaded binaries against published checksums.

Keep the authentication file, candidate inputs and captured outputs outside Git
and Homelab. Set `AUTH_FILE` to the external pull-secret path and `OUT` to a new
protected evidence directory. Record source commit, input hashes, date and tool versions.
Never print or hash the credential file into shared evidence.

## Select and verify

1. Check the live target OSC matrix, Operator lifecycle/entitlements and OCP update
   graph. Choose exact versions deliberately; a channel head is not an upgrade proof.
2. Fetch the catalog's **raw** manifest with Skopeo, compute its digest, and fetch
   again by that digest. The bytes/digest must agree. Preserve the top-level index
   pin; select and independently check the Linux/AMD64 child for rendering.
3. Render only the pinned catalog with opm and validate its file-based catalog.
   Confirm exact package, included channel, CSV and `olm.package` version for each selection.
4. Independently render each pinned bundle. Compare its actual CSV, package/version,
   dependency properties and related images with the catalog. Decode bundle objects
   before comparing: catalog and bundle representation properties differ.
5. Resolve every advertised related image and each helper/diagnostic image by the
   same raw-manifest/digest-reread method. Check architecture for the deployed images.
6. Review package/GVK/constraint dependencies and deprecations. Add required packages
   explicitly: oc-mirror v2 does not infer these dependencies.

A basic registry check is:

```bash
skopeo inspect --authfile "$AUTH_FILE" --tls-verify=true --raw \
  "docker://<selected-image-ref>" > "$OUT/manifest.json"
skopeo manifest-digest "$OUT/manifest.json"
```

Fetch the returned digest reference again and compare raw bytes. Do not reserialize
JSON before hashing. For the tested opm build, authentication required
`DOCKER_CONFIG/config.json`; `REGISTRY_AUTH_FILE` alone did not work. Point that
external config at the existing auth file, then `opm render <pinned-amd64-catalog> -o json`
and `opm validate <catalog-directory>`.

See [the FBC schema](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
and [oc-mirror v2 filtering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2)
for channel/default-channel and exact-version rules.

## Update the matching files

| File | Values to keep aligned |
|---|---|
| `install/release-manifest.json` | Platform, catalog/bundle/image pins, exact package/channel/CSV/version, complete dependencies, evidence date/hashes |
| `install/imageset-config.yaml` | Same catalog/helper images, exact operator version ranges, dependencies and included default channels |
| `gitops/base/operators/subscriptions.yaml` | Same package/channel/source/startingCSV; keep Manual approval |
| `gitops/base/gatekeeper/operator.yaml` | Same Gatekeeper selection and Manual approval |

Stage candidate manifest/ImageSet files externally and review matching Subscription
edits. Mark `resolution: verified` only after registry and metadata checks pass.
Do not change hardware/compatibility/upgrade flags merely because resolution succeeded.
Confirm Gatekeeper's applicable subscription entitlement separately from registry access.

Run the candidate checks:

```bash
IMAGESET_CONFIG="$OUT/imageset-config.resolved.yaml" \
  python3 scripts/verify-release.py \
  --manifest "$OUT/release-manifest.resolved.json" --require-resolved
(
  cd "$OUT"
  env -u REGISTRY_AUTH_FILE oc mirror --authfile "$AUTH_FILE" \
    --cache-dir "$OUT/mirror-cache" -c "$OUT/imageset-config.resolved.yaml" \
    "file://$OUT/mirror-preview" --dry-run --v2
)
```

The verifier reads Subscriptions from the checkout. For the tested oc-mirror build,
unset `REGISTRY_AUTH_FILE` and avoid a destination component literally named `dry-run`.
Inspect the planned mapping for every required source; an empty cache before the first
transfer is expected. A dry run does not prove successful mirroring.

Review the nonsecret diff and evidence, then update the manifest/ImageSet together
and run `make preflight`. Verify the real mirror's CatalogSource and package/CSV/bundle
inventory before installation. Preserve resolution evidence with each validation run.
