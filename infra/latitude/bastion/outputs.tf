output "virtual_network_id" {
  value       = latitudesh_virtual_network.rig.id
  description = "Consumed by the SNP node module (../) via terraform_remote_state to join the VLAN."
}

output "virtual_network_vid" {
  value       = latitudesh_virtual_network.rig.vid
  description = "VLAN tag id — needed to configure the node's tagged sub-interface (agent-config nmstate / NM)."
}

output "firewall_id" {
  value       = latitudesh_firewall.node_inbound.id
  description = "Consumed by the SNP node module to attach the inbound-hardening firewall (egress = host nftables)."
}

output "bastion_public_ipv4" {
  value       = latitudesh_server.bastion.primary_ipv4
  description = "Public IP — SSH admin + the bastion's own internet egress while mirroring."
}

output "bastion_vlan_ip" {
  value       = var.bastion_vlan_ip
  description = "Private VLAN IP the mirror is served on; the node's egress nftables allow ONLY this."
}

output "mirror_endpoint" {
  value       = "${var.registry_dns_name}:8443"
  description = "MIRROR_REGISTRY host:port (DNS name, not IP — cert SAN matches). Wire into install-config + `make mirror`."
}

output "node_hosts_entry" {
  value       = "${var.bastion_vlan_ip} ${var.registry_dns_name}"
  description = "Add to the SNP node's host resolution (agent-config / MachineConfig) so the mirror name resolves over the VLAN."
}

output "ssh_hint" {
  # VERIFY the cloud-image login user on first connect: Rocky/Alma images conventionally use
  # "rocky"/"cloud-user"; Latitude may instead enable root. Falls back across the likely users.
  value = "ssh ${startswith(var.operating_system, "rocky") ? "rocky" : (startswith(var.operating_system, "ubuntu") ? "ubuntu" : "cloud-user")}@${latitudesh_server.bastion.primary_ipv4}  # (try root@ if refused) — bootstrap log: /var/log/mirror-bootstrap.log; ready when ${var.mirror_root}/MIRROR_READY exists"
}
