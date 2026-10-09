# GitOps manifests

Kustomize renders the common manifests. Use the staged scripts for installation:
`make install-coco-operators` and `scripts/apply-trustee.sh bootstrap|configure`.
Applying a complete overlay directly bypasses dependency waits and inventory checks.

| Overlay | Intended scope |
|---|---|
| `sno-workers` | Disposable SNO worker stack; staged install requires `INSTALL_TOPOLOGY=sno TRUSTEE_LAB=1` |
| `customer-workers` | Separate worker cluster with explicit `node-role.kubernetes.io/coco-snp` pool selection |
| `sno-trustee`, `customer-trustee` | Restricted Trustee base; site TLS/resources are supplied out of band |

Co-located Permissive HTTP testing is selected through the scripts, not inferred
from an overlay name. The customer overlays are starting manifests and remain
unvalidated in the [completed SNO trial](../docs/validation/README.md).
`make render-overlay OVERLAY=<name>` inspects them without applying.

Versions come from [the release manifest](../install/release-manifest.json).
Worker installation waits for NFD discovery, scoped Kata convergence, `kata-cc`
with `kata-snp`, and Gatekeeper policy. Trustee configuration follows actual
Operator-owned resources; [the guide](../docs/trustee-current.md) describes the order.

Recollect VCEKs for the actual worker/TCB and recalculate approved launch references
when artifacts change. Initdata bytes, endpoint certificates and policies are
site/workload inputs, not portable historical proof. Use
[guest registry setup](../docs/guest-images.md) before launching workloads.
