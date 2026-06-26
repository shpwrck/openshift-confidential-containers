terraform {
  required_providers {
    latitudesh = {
      source  = "latitudesh/latitudesh"
      version = "~> 3.3" # resolved to v3.3.0
    }
  }
}

# Auth via env: export LATITUDESH_AUTH_TOKEN=...  (or set var.auth_token / TF_VAR_auth_token)
provider "latitudesh" {
  auth_token = var.auth_token != "" ? var.auth_token : null
}

# Use an EXISTING project id (recommended) to avoid project churn, or create one.
# Find it in the dashboard or `lsh projects list`.
resource "latitudesh_ssh_key" "rig" {
  count      = var.create_ssh_key ? 1 : 0
  name       = "coco-rig"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "latitudesh_server" "snp_rig" {
  project          = var.project
  hostname         = var.hostname
  plan             = var.plan             # Genoa SKU slug — confirm via the API discovery step
  site             = var.site             # metro with Genoa stock — confirm via the API discovery step
  operating_system = var.operating_system # rocky-10 (RHEL-family) for rung-0, or "ipxe" to netboot a custom image
  billing          = "hourly"             # destroy after the spike to control cost
  ssh_keys         = length(var.ssh_key_ids) > 0 ? var.ssh_key_ids : [for k in latitudesh_ssh_key.rig : k.id]

  # Custom image via iPXE: set operating_system="ipxe" and point ipxe at a boot script.
  ipxe = var.ipxe_url != "" ? var.ipxe_url : null

  # Optional cloud-init (e.g. install snpguest/qemu, confirm kernel) once booted.
  user_data = var.user_data != "" ? var.user_data : null
}

# --- Air-gap wiring: join the bastion's VLAN + attach its egress-lockdown firewall --------
# Gated on var.air_gap. With air_gap=false the node is a standalone rung-0 box (yesterday's
# path: provision, prove SNP host, destroy) needing no bastion. With air_gap=true (default)
# the bastion module must already be applied — we read its outputs from its local state.
data "terraform_remote_state" "bastion" {
  count   = var.air_gap ? 1 : 0
  backend = "local"
  config  = { path = var.bastion_state_path }
}

resource "latitudesh_vlan_assignment" "node" {
  count              = var.air_gap ? 1 : 0
  server_id          = latitudesh_server.snp_rig.id
  virtual_network_id = data.terraform_remote_state.bastion[0].outputs.virtual_network_id
}

# Attach the bastion's INBOUND-hardening firewall (SSH/API/ingress from admin_cidr only).
# This is NOT the air-gap egress control — egress is locked host-side with nftables (runbook
# Phase 1). Opt-in so a wrong admin_cidr can't lock you out of the node on first provision.
resource "latitudesh_firewall_assignment" "node" {
  count       = var.air_gap && var.enforce_latitude_firewall ? 1 : 0
  server_id   = latitudesh_server.snp_rig.id
  firewall_id = data.terraform_remote_state.bastion[0].outputs.firewall_id
}
