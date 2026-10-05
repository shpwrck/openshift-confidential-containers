# Latitude validation of the current release

## Status and scope

**Hardware validation in progress; SNP gate not passed.** [Dated preflight evidence](validation/latitude-preflight-2026-10-05.json) records the completed preparation checks and their limits. Sequential hardware candidates are authorized under the approved $150 total cap. Authenticated artifact resolution, actual image mirroring, registry TLS and DNS checks completed. An unchanged preparation rerun passed with zero changes and skipped transfer. Signed-image host verification accepted the signed control and rejected the same-content unsigned control for a signature-specific reason; guest enforcement remains untested.

Installer artifacts were generated successfully. PXE publication initially failed because nginx could not traverse the private installer directory. Moving the public copies to `/var/www/coco-boot-artifacts` passed the nginx read check, public HTTP 206 Range check and root-path 404 check. A repeat run reused the artifacts. Cleanup removed the webroots and boot configuration, closed port 8080 and made the tokenized endpoint unreachable. These checks used SELinux Permissive and did not boot the node.

The delivered node is EPYC 7313P / H12SSW-NTR / BIOS 2.3 / BMC 01.00.41, rather than the EPYC 9124 advertised for the selected plan. Saved SMEE, IOMMU, ASID and SNP settings exposed `/dev/sev`, but the host check still fails: BIOS did not reserve RMP memory and SNP remains disabled. A read-only sweep of all seven BIOS tabs, all 15 Advanced submenu roots and the documented nested menus exposed no RMP coverage control with the saved configuration. Disabled controls were not unlocked; the inspection ended with Discard Changes and Exit, without changes or flashing. The exact board's published BIOS 3.6/BMC 01.08.06 bundle addresses newer firmware needs, but has not been validated as a fix for this failure. Latitude's public console-access docs do not establish a customer flashing policy; a provider update or approved procedure/replacement is the next step. The support draft remains unsent. See [firmware preflight](amd-firmware-preflight.md) for scope, security fixes and update limits. No new OpenShift installation or guest proof has completed. The previous rig's July results remain historical evidence.

The complete run targets a disposable AMD SEV-SNP CPU environment. Intel and GPU work are outside this effort. This page plans fresh infrastructure and installation; the existing customer cluster follows a separate upgrade rehearsal.

The rejected Dallas node has been destroyed, with deletion confirmed through the provider API.
The next candidate in Miami delivered EPYC 9124 / H13SST-G / BIOS 1.6 and already boots in UEFI
mode. Its BIOS exposes RMP coverage; configuration and the post-reboot host check are in progress.
The Dallas bastion is retained temporarily. A usable candidate in another site needs a bastion
and VLAN in that same site; its firmware security level remains a separate acceptance question.

## Inputs required before provisioning

1. Verify [the resolved BOM](../install/release-manifest.json), using [the resolution procedure](release-resolution.md) when refreshing pins: immutable catalog and bundle identities, exact CSVs/channels, related images and helper images. `python3 scripts/verify-release.py --require-resolved` must pass.
2. Confirm access to the Latitude project and current stock for the selected site/plan, the intended SSH key, billing mode, admin CIDR and firmware access. Record server IDs once provisioned; do not assume old IDs still exist.
3. Select a **versioned HTTPS mirror-registry archive and its published SHA-256**. Set `mirror_registry_url` and `mirror_registry_sha256` in the bastion inputs. Both are required; there is no `latest` or unchecked fallback. The current run has verified mirror-registry 2.0.12 against the published SHA-256; the bastion guide records the pin and host prerequisites.
4. Keep the Red Hat pull secret, provider credential, SSH keys and any later kubeconfigs in private external storage. The wrapper accepts `COCO_BASTION_TFVARS` and `COCO_NODE_TFVARS` as absolute file paths; never put secret-bearing files or state under Homelab.
5. Complete an external Ansible environment file with reviewed networking, disk, NIC and boot-token inputs as described in [the quickstart](current-quickstart.md).

Select by the exact CPU and firmware, not just Latitude's “Gen 4” family label. Its
[public catalog](https://www.latitude.sh/pricing) currently lists `m4.metal.medium`
with EPYC 9124 and `m4.metal.large` with EPYC 9254; these are candidates to check against
the selected Red Hat support matrix and required capacity. Other similarly named plans
use different CPU families. Public listings do not establish account stock, enabled SNP,
firmware access or the final infrastructure price. Confirm those before creating servers.

## Plan and provision in stages

Qualify the actual node before building a new mirror bastion. The node module supports a standalone
provider OS with `air_gap=false`; it does not need a bastion for firmware checks. Set the external
node inputs to the intended project/site/plan, `operating_system="rocky-10"`, `air_gap=false`,
`create_ssh_key=false` and the verified existing `ssh_key_ids`. Keep the provider credential in
`LATITUDESH_AUTH_TOKEN`.

```bash
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
export COCO_BASTION_TFVARS="$COCO_STATE_DIR/bastion.tfvars"
export COCO_NODE_TFVARS="$COCO_STATE_DIR/node.tfvars"
umask 077
mkdir -p "$COCO_STATE_DIR"

# After filling and reviewing the external input files and resolving the BOM:
python3 scripts/verify-release.py --require-resolved
export COCO_NODE_STATE_DIR="$COCO_STATE_DIR/terraform/node"
mkdir -p "$COCO_NODE_STATE_DIR"
chmod 700 "$COCO_NODE_STATE_DIR"
export TF_DATA_DIR="$COCO_NODE_STATE_DIR/data"
terraform -chdir=infra/latitude init -input=false
terraform -chdir=infra/latitude plan \
  -state="$COCO_NODE_STATE_DIR/terraform.tfstate" -var-file="$COCO_NODE_TFVARS" \
  -out="$COCO_NODE_STATE_DIR/candidate.tfplan"
terraform -chdir=infra/latitude show "$COCO_NODE_STATE_DIR/candidate.tfplan"
# After reviewing the candidate plan:
terraform -chdir=infra/latitude apply \
  -state="$COCO_NODE_STATE_DIR/terraform.tfstate" "$COCO_NODE_STATE_DIR/candidate.tfplan"
terraform -chdir=infra/latitude output -state="$COCO_NODE_STATE_DIR/terraform.tfstate"
```

`TF_DATA_DIR` moves provider metadata, **not local state**. Every direct plan, apply, output and
destroy must select the same external state; applying a saved plan also needs `-state`.
If any state appears in the checkout, stop and reconcile its resource IDs and lineage before
continuing. Do not create a second state to manage the same server.

Match the returned server ID to SSH and the console, then complete [AMD firmware preflight](amd-firmware-preflight.md).
For a rejected candidate, retain its evidence and review a destroy plan using that same state and
input file. Apply the saved destroy plan with `-state`, and confirm the exact server is absent
from the provider before trying another allocation. Track cumulative cost, including deleted
candidates and any temporary overlap, against the total budget.

For an accepted candidate, retain its existing node state and unchanged server identity. Select
a bastion in the **same site**, then plan its infrastructure:

```bash
bash ansible/up.sh --mode prepare --plan-tf
```

The modules select Latitude provider 4.6.0 with committed lock files and `allow_reinstall=false`. If an existing checkout still has a 3.3 lock selection, update its provider installation with `terraform init -upgrade` using the same external `TF_DATA_DIR`, then review the new plan. A cloud-init change that requires a bastion reinstall must fail rather than silently replace its OS; handle that replacement as a separate deliberate operation.

Inspect the plan for the intended project, site, machine, VLAN, firewall and billing. A plan is not an apply. The wrapper's `--plan-tf` runs no Ansible tasks. Terraform init may download providers and planning may read provider state, but neither should provision resources.

Provision the bastion before enabling the node's VLAN dependency. Once the bastion plan is acceptable:

```bash
bash ansible/up.sh --mode prepare --apply-tf -e "@$COCO_STATE_DIR/rig.yml"
# Set air_gap=true in the SAME node input file, retaining its existing server inputs/state.
# The bastion state now permits the node's VLAN/firewall dependency to resolve.
bash ansible/up.sh --mode fresh-install --plan-tf
```

The node plan should preserve the accepted server and add only the intended VLAN and optional
firewall assignments. Investigate a replacement or reinstall instead of applying it. Keep the
provider OS input unchanged; Ansible's journaled installation step requests the later netboot.

If preparation stops because its new-host inputs are incomplete, preserve the external Terraform state, correct the inputs, and rerun preparation. Do not create a second state directory for the same project resources. Pull-secret staging accepts `pull_secret_src` from the external Ansible file. Check the bastion's `MIRROR_READY`/`MIRROR_FAILED` result and its protected bootstrap logs before retrying a failed bootstrap.

After reviewing the node plan and completing [AMD firmware preflight](amd-firmware-preflight.md) for the actual delivered board, UEFI boot path, firmware security fixes and raw-host SNP result:

```bash
bash ansible/up.sh --mode fresh-install --apply-tf -e "@$COCO_STATE_DIR/rig.yml"
bash ansible/up.sh --mode verify -e "@$COCO_STATE_DIR/rig.yml"
```

`--apply-tf` is explicit and Terraform retains its own approval prompt. Fresh install retains the BIOS gate. The provider reinstall step compares the returned machine ID with the requested ID, persists request intent before sending it, and does not repeat an accepted request for unchanged inputs. If a request fails ambiguously, inspect the provider before any retry.

The wrapper passes non-secret Terraform outputs into Ansible after apply. When using already provisioned machines without `--apply-tf`, supply their current bastion IP, VLAN VID and server ID in the external Ansible file.

## Acceptance evidence

Save each run's dated evidence outside the repository. Report **PASS**, **FAIL**, or **INCOMPLETE** per checkpoint; failed connectivity or missing prerequisites do not count as denial proofs.

| Checkpoint | Evidence required |
|---|---|
| Identity and release | Git commit, resolved BOM digest, project/site/server IDs, firmware state, actual OCP version and payload digest, operator CSVs and related-image digests. |
| Bootstrap reliability | Tool hashes; a repeated unchanged run reuses artifacts; a changed input triggers the relevant mirror/PXE work; no unsupported fallback. Record first-run timings and intervention count. |
| Offline image path | Successful mirror, generated/applied mirror resources, target registry reachability, workload pulls through the mirror, and observed node egress policy. A local `MIRROR_READY` file alone is insufficient. |
| Runtime | Target CPU capability, RuntimeClass `kata-cc` resolving to handler `kata-snp`, hardware-backed guest launch, and selected node identity. |
| Trustee | Exact Operator/CR schema; generated resource ownership and readiness; preserved signer identity; required TLS; approved default-deny policy and target RVPS/collateral identity. |
| Security behavior | Fresh positive control, one isolated mutation, attributable denial, restoration, and a new successful control for KBS, initdata, RVPS and signed-image proofs. |
| Missing collateral | Denial without the approved endorsement material, then recovery after restoring it. Separately demonstrate the network egress constraint. |
| Resource behavior | Actual guest memory/CPU settings, cold and warm start times, and node allocatable impact. Larger memory defaults are a workaround until measured on the selected payload. |
| Cleanup | Proof resources restored/removed; secret-bearing boot endpoint unreachable; saved evidence contains no credentials; provider inventory confirms intended teardown. |

Do not promote encrypted-image or GPU support based on these CPU results. Any encrypted-image experiment must separately prove key wrapping, pull/decrypt/execute, attributable denial and recovery on the actual selected guest payload. The default acceptance gate excludes it.

## Close the endpoint and tear down

The successful wrapper closes its PXE endpoint. If a run stops early, use the explicit `pxe-stop` command in [the quickstart](current-quickstart.md#prepare-install-verify) once the node no longer needs the assets, and verify the old boot URL is unreachable without copying its token into shared evidence.

Keep state until provider cleanup is verified. Destroy the node first because it depends on the bastion's VLAN. Review destroy plans before applying them; the following commands explicitly destroy the disposable rig:

```bash
TF_DATA_DIR="$COCO_STATE_DIR/terraform/node/data" terraform -chdir=infra/latitude destroy \
  -state="$COCO_STATE_DIR/terraform/node/terraform.tfstate" \
  -var-file="$COCO_NODE_TFVARS" \
  -var="bastion_state_path=$COCO_STATE_DIR/terraform/bastion/terraform.tfstate"
TF_DATA_DIR="$COCO_STATE_DIR/terraform/bastion/data" terraform -chdir=infra/latitude/bastion destroy \
  -state="$COCO_STATE_DIR/terraform/bastion/terraform.tfstate" \
  -var-file="$COCO_BASTION_TFVARS"
```

Confirm the target servers and their rig-only assignments are absent in provider inventory and billing. A failed SSH connection is not teardown evidence. Retain the sanitized run record and remove sensitive temporary artifacts according to the environment's retention policy.
