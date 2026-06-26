output "virtual_network_id" {
  value       = latitudesh_virtual_network.rig.id
  description = "Consumed by the SNP node module (../) via terraform_remote_state to join the VLAN."
}

output "firewall_id" {
  value       = latitudesh_firewall.node_inbound.id
  description = "Consumed by the SNP node module to attach the inbound-hardening firewall (egress = host nftables)."
}

output "bastion_public_ipv4" {
  value       = latitudesh_server.bastion.primary_ipv4
  description = "Public IP — used for SSH admin + the bastion's own internet egress while mirroring."
}

output "mirror_endpoint" {
  value       = "${latitudesh_server.bastion.primary_ipv4}:8443"
  description = "MIRROR_REGISTRY host:port. Wire into install-config imageDigestSources + `make mirror`. VERIFY port."
}

output "ssh_hint" {
  value = "ssh ${split("_", var.operating_system)[0] == "ubuntu" ? "ubuntu" : "root"}@${latitudesh_server.bastion.primary_ipv4}  # mirror-registry bootstrap log: /var/log/cloud-init-output.log"
}
