# operators base

Namespaces, OperatorGroups, and Subscriptions for the four operators, in install order:

    NFD -> cert-manager -> OSC -> Trustee

## Air-gap: CatalogSource comes from oc-mirror

These Subscriptions point `source` at a **mirrored** CatalogSource in
`openshift-marketplace` (e.g. `cs-redhat-operator-index-v4-20`), **not** the public Red Hat
catalog. That CatalogSource object is produced by `oc-mirror` (the `oc-mirror` output applies
an `ImageDigestMirrorSet` plus the CatalogSource). It is therefore **not** in this base —
it is created by the mirror/install tooling (owned by `install/**`). If you rename your
mirror set, update the `source:` field in `subscriptions.yaml` to match.

Verify the actual catalog/channel/CSV names against the mirror before applying:

    oc get catalogsource -n openshift-marketplace
    oc get packagemanifest <pkg> -n openshift-marketplace -o yaml | yq '.status.channels'

Every `# VERIFY` channel and `# FILL` CSV comment marks a value that must be confirmed
against your specific mirrored catalog.

## Pull secret

The cluster-wide pull secret (`openshift-config/pull-secret`) that lets nodes pull the
mirrored operator images is **created out-of-band**, never committed. See
`../trustee/secret-stubs.example.yaml` for the secret-handling convention.
