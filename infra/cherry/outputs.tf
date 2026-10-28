module "rig_values" {
  source     = "./modules/rig_values"
  project_id = var.project_id
  servers = {
    node   = cherryservers_server.node
    helper = cherryservers_server.helper
  }
}

output "node_public_ipv4" {
  description = "SSH target for the node's original OS."
  value       = module.rig_values.node_public_ipv4
}

output "helper_public_ipv4" {
  description = "SSH target for the helper."
  value       = module.rig_values.helper_public_ipv4
}

output "rig_values" {
  description = "The values Cherry assigned, for scripts/order-rig.py to write into the rig file."
  value       = module.rig_values.rig_values
}
