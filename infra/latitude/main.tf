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
  operating_system = var.operating_system # "ipxe" for the Ubuntu 25.04 netboot path, else a stock slug
  billing          = "hourly"             # destroy after the spike to control cost
  ssh_keys         = length(var.ssh_key_ids) > 0 ? var.ssh_key_ids : [for k in latitudesh_ssh_key.rig : k.id]

  # Ubuntu 25.04 via iPXE: set operating_system="ipxe" and point ipxe at a boot script.
  ipxe = var.ipxe_url != "" ? var.ipxe_url : null

  # Optional cloud-init (e.g. install snpguest/qemu, confirm kernel) once booted.
  user_data = var.user_data != "" ? var.user_data : null
}
