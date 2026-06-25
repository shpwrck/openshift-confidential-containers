output "server_id" {
  value = latitudesh_server.snp_rig.id
}

output "primary_ipv4" {
  value       = latitudesh_server.snp_rig.primary_ipv4
  description = "SSH target for scripts/host-snp-check.sh"
}

output "ssh_hint" {
  value = "ssh root@${latitudesh_server.snp_rig.primary_ipv4}  # then: scp scripts/host-snp-check.sh and run it"
}
