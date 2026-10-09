# Operator base

Namespaces, OperatorGroups and Manual Subscriptions for NFD, cert-manager, OSC and
Trustee. Gatekeeper's Subscription lives in [its base](../gatekeeper/operator.yaml).
The [release manifest](../../../install/release-manifest.json) defines exact selections.

The staged worker installer orders prerequisites, validates matching InstallPlans
and waits for successful CSVs before applying operands. Customer worker installs
exclude Trustee; install its Operator separately in the intended Trustee cluster.

Subscriptions use the mirrored CatalogSource produced by oc-mirror and checked by
the installation tooling. Confirm its actual name, catalog image and selected
package/channel/CSV/bundle inventory before approval. Keep public default catalogs
and floating selections out of the disconnected path.

Provision cluster pull authentication out of band. Trustee resource Secrets are
separate from the host pull secret; see [Trustee setup](../../../docs/trustee-current.md).
