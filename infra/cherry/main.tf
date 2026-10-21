# Orders the AMD node and the mirror/admin helper. Everything after ordering
# (the helper's mirror bootstrap, the node's iPXE rebuild into OpenShift) runs
# over SSH or through Ansible.

resource "cherryservers_ssh_key" "rig" {
  count      = length(var.ssh_key_ids) == 0 ? 1 : 0
  name       = "${var.node_hostname}-rig"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
}

locals {
  ssh_key_ids = length(var.ssh_key_ids) > 0 ? var.ssh_key_ids : toset([for key in cherryservers_ssh_key.rig : key.id])
}

resource "cherryservers_server" "node" {
  project_id  = var.project_id
  region      = var.region
  plan        = var.node_plan
  image       = var.node_image
  hostname    = var.node_hostname
  ssh_key_ids = local.ssh_key_ids
  cycle       = var.billing_cycle
  tags        = var.tags

  lifecycle {
    # Ansible rebuilds this server into OpenShift through the Cherry API, so
    # its image and boot settings drift on purpose. Never let a later apply
    # reinstall it; replace or destroy it explicitly instead.
    ignore_changes = [image, ipxe, persist_ipxe, user_data, os_partition_size, ssh_key_ids]
  }
}

resource "cherryservers_server" "helper" {
  project_id  = var.project_id
  region      = var.region
  plan        = var.helper_plan
  image       = var.helper_image
  hostname    = var.helper_hostname
  ssh_key_ids = local.ssh_key_ids
  cycle       = var.billing_cycle
  tags        = var.tags
  # No user data: Cherry Servers installs neither the order's SSH key nor the
  # private VLAN on a server ordered with it. The mirror bootstrap runs over
  # SSH once the helper is up (docs/cherry-servers.md).
}
