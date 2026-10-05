output "server_id" {
  value = latitudesh_server.snp_rig.id
}

output "primary_ipv4" {
  value       = latitudesh_server.snp_rig.primary_ipv4
  description = "SSH target for scripts/host-snp-check.sh"
}

output "ssh_hint" {
  value = (
    startswith(var.operating_system, "rocky-") ?
    "ssh rocky@${latitudesh_server.snp_rig.primary_ipv4}  # then: scp scripts/host-snp-check.sh and run it" :
    startswith(var.operating_system, "ubuntu_") ?
    "ssh ubuntu@${latitudesh_server.snp_rig.primary_ipv4}  # then: scp scripts/host-snp-check.sh and run it" :
    "Use the ${var.operating_system} image's documented SSH account for ${latitudesh_server.snp_rig.primary_ipv4}; then copy scripts/host-snp-check.sh and run it."
  )
}
