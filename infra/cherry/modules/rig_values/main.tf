# Turns the two servers' Cherry API addresses into rig-file lines. Kept free of
# providers so terraform test can check it offline.

variable "project_id" {
  type = number
}

variable "servers" {
  description = "The node and the helper as the Cherry provider reports them."
  type = map(object({
    id       = string
    hostname = string
    ip_addresses = set(object({
      type           = string
      address_family = number
      address        = string
      cidr           = string
      vlan_id        = optional(number)
    }))
  }))

  validation {
    condition     = toset(keys(var.servers)) == toset(["node", "helper"])
    error_message = "Pass exactly the node and the helper."
  }
}

locals {
  ipv4 = {
    for name, server in var.servers : name => {
      public  = one([for ip in server.ip_addresses : ip if ip.type == "primary-ip" && ip.address_family == 4])
      private = one([for ip in server.ip_addresses : ip if ip.type == "private-ip" && ip.address_family == 4])
    }
  }
  # cidrsubnet(x, 0, 0) turns "10.191.48.7/24" or "10.191.48.0/24" into the network.
  private_network = {
    for name, addresses in local.ipv4 : name => try(cidrsubnet(addresses.private.cidr, 0, 0), null)
  }
  vlan_tag = try(local.ipv4.node.private.vlan_id > 0 ? tostring(local.ipv4.node.private.vlan_id) : null, null)
}

output "node_public_ipv4" {
  value = try(local.ipv4.node.public.address, null)
}

output "helper_public_ipv4" {
  value = try(local.ipv4.helper.public.address, null)
}

output "rig_values" {
  description = "The values Cherry assigned, for scripts/order-rig.py to write into the rig file."
  value = {
    project_id          = tostring(var.project_id)
    node_id             = var.servers.node.id
    node_hostname       = var.servers.node.hostname
    node_public_ipv4    = local.ipv4.node.public.address
    node_private_ipv4   = local.ipv4.node.private.address
    helper_id           = var.servers.helper.id
    helper_hostname     = var.servers.helper.hostname
    helper_public_ipv4  = local.ipv4.helper.public.address
    helper_private_ipv4 = local.ipv4.helper.private.address
    private_network     = local.private_network.node
    # null when the API reports no tag; the rig file then takes the tag seen on the node.
    vlan_tag = local.vlan_tag
  }

  precondition {
    condition = alltrue([
      for name, addresses in local.ipv4 : addresses.public != null && addresses.private != null
    ])
    error_message = "Each server needs exactly one public and one private IPv4 address. Check them in the Cherry portal."
  }
  precondition {
    condition     = local.private_network.node != null && local.private_network.node == local.private_network.helper
    error_message = "The node and the helper are not on the same private network. Cherry VLANs do not span switches: replace the helper (terraform apply -replace=cherryservers_server.helper) or ask Cherry support to move it."
  }
  precondition {
    condition     = try(local.ipv4.node.private.vlan_id == local.ipv4.helper.private.vlan_id, false)
    error_message = "The node and the helper report different private VLANs. Cherry VLANs do not span switches: replace the helper or ask Cherry support to move it."
  }
}
