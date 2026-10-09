# Latitude Terraform modules

These modules provision a disposable AMD node and a separate mirror helper.
The October 5 trial was [retired](../../docs/validation/latitude-retirement-2026-10-05.json)
without an OpenShift install because private-network qualification failed.
They are retained infrastructure code, not a qualified provider recommendation.
[Cherry](../../docs/cherry-validation.md) was the successful supplied-rig path.

## Inputs and state

Before allocating, confirm actual CPU/board, firmware/UEFI/SNP, console access,
site stock, current price and total budget. A provider plan name does not guarantee
identical hardware. Complete [firmware preflight](../../docs/amd-firmware-preflight.md)
on the delivered node before committing to installation.

Copy [node](terraform.tfvars.example) and [helper](bastion/terraform.tfvars.example)
inputs to private external files. Keep `LATITUDESH_AUTH_TOKEN` in the environment;
never put its value, secret-bearing tfvars or state under the checkout/Homelab.
The provider is pinned to 4.6.0 and `allow_reinstall=false`.

```bash
export COCO_STATE_DIR="$HOME/.local/state/openshift-confidential-containers"
export COCO_NODE_TFVARS="$COCO_STATE_DIR/node.tfvars"
export COCO_BASTION_TFVARS="$COCO_STATE_DIR/bastion.tfvars"
```

Use one authoritative state per module:
`$COCO_STATE_DIR/terraform/node/terraform.tfstate` and
`$COCO_STATE_DIR/terraform/bastion/terraform.tfstate`.
`TF_DATA_DIR` moves provider metadata, not state. Select `-state` on every direct
plan/apply/output/destroy, including saved-plan apply. Reconcile any in-checkout
state before continuing; do not create duplicate ownership.

## Provisioning order

1. Screen a candidate node with `air_gap=false`, the intended project/site/key and
   provider OS. Plan/apply directly with the node's external state and tfvars.
2. For an accepted node, plan the helper in the **same site** with
   `bash ansible/up.sh --mode prepare --plan-tf`. Review identities, price and assignments.
3. Explicitly apply with `--mode prepare --apply-tf -e "@$COCO_STATE_DIR/rig.yml"`.
   [Helper prerequisites](bastion/README.md) cover registry bootstrap and its limits.
4. Set `air_gap=true` in the same node input file. Review a node plan using its
   existing state and `bastion_state_path`; it should add assignments and preserve
   the server. Apply only those changes while the provider OS is still available.
5. Prove the actual node-to-helper registry TLS, DNS, NTP and direct private routing
   before any reinstall. The previous provider trial failed this gate.

A representative node plan is:

```bash
umask 077
mkdir -p "$COCO_STATE_DIR/terraform/node"
export TF_DATA_DIR="$COCO_STATE_DIR/terraform/node/data"
terraform -chdir=infra/latitude init -input=false
terraform -chdir=infra/latitude plan \
  -state="$COCO_STATE_DIR/terraform/node/terraform.tfstate" \
  -var-file="$COCO_NODE_TFVARS" \
  -out="$COCO_STATE_DIR/terraform/node/review.tfplan"
terraform -chdir=infra/latitude show "$COCO_STATE_DIR/terraform/node/review.tfplan"
```

For the private assignment stage, also pass
`-var="bastion_state_path=$COCO_STATE_DIR/terraform/bastion/terraform.tfstate"`.
Keep `enforce_latitude_firewall=false`: it selects only an API assignment; the repo
does not install or verify the provider's host firewall agent. VLAN membership also
does not prove isolation. Ansible's journaled reinstall is a separate explicit step.

## Cleanup

Back up configuration/state first. Destroy node before helper, preserving the
original input files and state. These commands prompt for the destroy plan:

```bash
TF_DATA_DIR="$COCO_STATE_DIR/terraform/node/data" terraform -chdir=infra/latitude destroy \
  -state="$COCO_STATE_DIR/terraform/node/terraform.tfstate" \
  -var-file="$COCO_NODE_TFVARS" \
  -var="bastion_state_path=$COCO_STATE_DIR/terraform/bastion/terraform.tfstate"
TF_DATA_DIR="$COCO_STATE_DIR/terraform/bastion/data" terraform -chdir=infra/latitude/bastion destroy \
  -state="$COCO_STATE_DIR/terraform/bastion/terraform.tfstate" \
  -var-file="$COCO_BASTION_TFVARS"
```

Verify intended objects are absent in fresh provider inventory; failed SSH is not
teardown evidence. If a changed bootstrap causes `Server Reinstall Required`
during destroy planning, use the recorded deployed configuration and review a
saved deletion-only plan. Keep `allow_reinstall=false`.

An interrupted create can leave a billable server before its ID reaches Terraform
state. Inspect inventory/state before retrying. Once the old process has exited,
back up state, import the verified existing ID if missing, and review a new plan.
