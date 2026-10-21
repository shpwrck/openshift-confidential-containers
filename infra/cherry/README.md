# Cherry Servers Terraform

Orders the AMD node and the mirror/admin helper in one Cherry Servers project and
region, so they share its private VLAN. The helper gets the cloud-init user data from
[`scripts/render-helper-bootstrap.py`](../../scripts/render-helper-bootstrap.py),
and the `rig_values` output starts the Ansible rig file with the addresses, IDs and
VLAN tag Cherry assigned. Everything after ordering is Ansible's job; the node is
never reinstalled by Terraform.

Follow [Cherry Servers setup](../../docs/cherry-servers.md#order-the-servers) to use it.
State and variables live in `COCO_STATE_DIR`, outside the checkout.

| File | Contents |
|---|---|
| `versions.tf` | Terraform and provider pins (provider 1.6.0, checked against `.terraform.lock.hcl`) and the local backend |
| `variables.tf`, `terraform.tfvars.example` | Inputs: project, region, plans, images, SSH key, user data file |
| `main.tf` | The SSH key, the node and the helper |
| `outputs.tf`, `modules/rig_values/` | Public addresses and the rig-file lines, with checks that both servers share a private network |
| `tests/` | Offline `terraform test` cases with a mocked provider; CI runs them |
