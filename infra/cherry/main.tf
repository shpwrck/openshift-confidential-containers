# Orders the AMD node and the mirror/admin helper. Everything after ordering
# (helper preparation, the node's iPXE rebuild into OpenShift) is Ansible's job.

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
  # The bootstrap adopts the helper's own private VLAN address at first boot,
  # so the user data does not depend on anything assigned during ordering.
  user_data = filebase64(pathexpand(var.helper_user_data_file))

  lifecycle {
    # cloud-init runs once. A re-rendered file only takes effect on a new
    # helper: terraform apply -replace=cherryservers_server.helper
    ignore_changes = [user_data]
  }
}
