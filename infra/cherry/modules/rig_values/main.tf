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
  # An unknown tag stays a placeholder, which Ansible refuses to install with.
  vlan_tag = try(local.ipv4.node.private.vlan_id > 0 ? tostring(local.ipv4.node.private.vlan_id) : null, null)
}

output "node_public_ipv4" {
  value = try(local.ipv4.node.public.address, null)
}

output "helper_public_ipv4" {
  value = try(local.ipv4.helper.public.address, null)
}

output "rig_values" {
  value = join("\n", [
    "",
    "# ---- From the Cherry Servers API (terraform output rig_values) ----",
    "bastion_ansible_host: \"${local.ipv4.helper.public.address}\"",
    "bastion_public_ipv4_override: \"${local.ipv4.helper.public.address}\"",
    "node_server_id: \"${var.servers.node.id}\"",
    "node_provider_hostname: \"${var.servers.node.hostname}\"",
    "node_provider_project_id: \"${var.project_id}\"",
    "node_vlan_ip: \"${local.ipv4.node.private.address}\"",
    "bastion_vlan_ip: \"${local.ipv4.helper.private.address}\"",
    "machine_network: \"${local.private_network.node}\"",
    "vlan_cidr: \"${local.private_network.node}\"",
    "vlan_prefix: ${split("/", local.private_network.node)[1]}",
    "# Ansible checks this tag against the node's and the helper's VLAN interfaces.",
    "vlan_vid_override: \"${coalesce(local.vlan_tag, "REPLACE_WITH_VLAN_TAG")}\"",
    "",
  ])

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
