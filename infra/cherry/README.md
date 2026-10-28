# Cherry Servers Terraform

Orders the AMD node and the mirror/admin helper in one Cherry Servers project and
region, so they share its private VLAN. Neither server gets user data: Cherry then
skips the SSH key and the private VLAN. `make order-rig`
([`scripts/order-rig.py`](../../scripts/order-rig.py)) writes the variables, runs
Terraform, and turns the `rig_values` output (the addresses, IDs and VLAN tag
Cherry assigned) into the Ansible rig file. The node is never reinstalled by
Terraform.

Follow [quickstart step 2](../../docs/quickstart.md#2-order-the-rig) to use it.
State and variables live in `COCO_STATE_DIR`, outside the checkout.

| File | Contents |
|---|---|
| `versions.tf` | Terraform and provider pins (provider 1.6.0, checked against `.terraform.lock.hcl`) and the local backend |
| `variables.tf`, `terraform.tfvars.example` | Inputs: project, region, plans, images, SSH key |
| `tested-plans.json` | The plans and images that completed a full run; `make order-rig` offers these first |
| `main.tf` | The SSH key, the node and the helper |
| `outputs.tf`, `modules/rig_values/` | Public addresses and the values for the rig file, with checks that both servers share a private network |
| `tests/` | Offline `terraform test` cases with a mocked provider; CI runs them |
