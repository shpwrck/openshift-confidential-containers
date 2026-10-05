# Latitude validation of the current release

## Status and scope

**Pending hardware validation.** The current checkout has local regression tests for tools, mirrors, PXE assets, provider request handling and proof logic. No new Latitude servers, live provider requests, SSH sessions or OpenShift deployments were created by these implementation tests. The previous rig was torn down; its July results are historical evidence, not results for OCP 4.20.39 / OSC 1.13 / Trustee 1.2.

The complete run targets a disposable AMD SEV-SNP CPU environment. Intel and GPU work are outside this effort. This page plans fresh infrastructure and installation; the existing customer cluster follows a separate upgrade rehearsal.

## Inputs required before provisioning

1. Resolve [the BOM](../install/release-manifest.json): immutable catalog and bundle identities, exact CSVs/channels, related images and helper images. `python3 scripts/verify-release.py --require-resolved` must pass.
2. Confirm access to the Latitude project and current stock for the selected site/plan, the intended SSH key, billing mode, admin CIDR and firmware access. Record server IDs once provisioned; do not assume old IDs still exist.
3. Select a **versioned HTTPS mirror-registry archive and its published SHA-256**. Set `mirror_registry_url` and `mirror_registry_sha256` in the bastion inputs. Both are required; there is no `latest` or unchecked fallback. The implementation does not claim that a new archive pin has already been verified.
4. Keep the Red Hat pull secret, provider credential, SSH keys and any later kubeconfigs in private external storage. The wrapper accepts `COCO_BASTION_TFVARS` and `COCO_NODE_TFVARS` as absolute file paths; never put secret-bearing files or state under Homelab.
5. Complete an external Ansible environment file with reviewed networking, disk, NIC and boot-token inputs as described in [the quickstart](current-quickstart.md).

## Plan and provision in stages

These commands are an operator procedure; they have not been executed against the provider during implementation.

```bash
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
export COCO_BASTION_TFVARS="$COCO_STATE_DIR/bastion.tfvars"
export COCO_NODE_TFVARS="$COCO_STATE_DIR/node.tfvars"
umask 077
mkdir -p "$COCO_STATE_DIR"

# After filling and reviewing the external input files and resolving the BOM:
bash ansible/up.sh --mode prepare --plan-tf
```

The modules select Latitude provider 4.6.0 with committed lock files and `allow_reinstall=false`. If an existing checkout still has a 3.3 lock selection, update its provider installation with `terraform init -upgrade` using the same external `TF_DATA_DIR`, then review the new plan. A cloud-init change that requires a bastion reinstall must fail rather than silently replace its OS; handle that replacement as a separate deliberate operation.

Inspect the plan for the intended project, site, machine, VLAN, firewall and billing. A plan is not an apply. The wrapper's `--plan-tf` runs no Ansible tasks. Terraform init may download providers and planning may read provider state, but neither should provision resources.

Start with the bastion because the node plan consumes its VLAN/firewall outputs. Once the bastion plan is acceptable:

```bash
bash ansible/up.sh --mode prepare --apply-tf -e "@$COCO_STATE_DIR/rig.yml"
# The existing bastion state now permits the node's remote-state dependency to resolve.
bash ansible/up.sh --mode fresh-install --plan-tf
```

If preparation stops because its new-host inputs are incomplete, preserve the external Terraform state, correct the inputs, and rerun preparation. Do not create a second state directory for the same project resources. Pull-secret staging accepts `pull_secret_src` from the external Ansible file. Check the bastion's `MIRROR_READY`/`MIRROR_FAILED` result and its protected bootstrap logs before retrying a failed bootstrap.

After reviewing the node plan and completing the required firmware verification:

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
