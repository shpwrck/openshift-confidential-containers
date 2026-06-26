variable "auth_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Latitude API token. Prefer the LATITUDESH_AUTH_TOKEN env var over setting this."
}

variable "project" {
  type        = string
  description = "Existing Latitude project id (proj_...). Same project as the SNP node."
}

variable "site" {
  type        = string
  description = "Metro/site — MUST match the SNP node's site (virtual networks are site-scoped)."
}

variable "hostname" {
  type    = string
  default = "coco-bastion"
}

variable "plan" {
  type        = string
  description = "Cheapest metal plan with enough disk for the mirror cache (no SNP needed). `lsh plans list`."
}

variable "operating_system" {
  type        = string
  default     = "ubuntu_26_04_x64_lts"
  description = "Bastion OS. Defaults to the proven Ubuntu slug; cloud-init adds podman + mirror-registry."
}

variable "billing" {
  type        = string
  default     = "hourly"
  description = "\"hourly\" while actively engaged; switch to \"monthly\" if the bastion runs for weeks."
}

variable "ssh_key_ids" {
  type        = list(string)
  description = "Existing Latitude ssh key ids to inject (same key as the node)."
}

variable "tags" {
  type    = list(string)
  default = []
}

# --- Firewall: INBOUND hardening for the node -------------------------------------------
# No default — fail closed. Set your admin source CIDR explicitly (the rig may use a wide
# range, but that must be a conscious choice, not a shipped 0.0.0.0/0). NB: this firewall
# hardens INBOUND to the node only; the air-gap EGRESS lockdown is host-nftables (runbook),
# not this resource.
variable "admin_cidr" {
  type        = string
  description = "Admin source CIDR allowed inbound to the node (SSH/API). Required — set consciously."
}

# --- mirror-registry bootstrap ----------------------------------------------------------
variable "mirror_init_user" {
  type        = string
  default     = "init"
  description = "Initial mirror-registry (quay) admin username. (The PASSWORD is generated on the bastion, not set here.)"
}

variable "mirror_root" {
  type        = string
  default     = "/opt/mirror"
  description = "Persistent on-disk root for the quay data + oc-mirror workspace (the cacheable bottleneck)."
}

variable "mirror_registry_url" {
  type        = string
  default     = "https://mirror.openshift.com/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz"
  description = "mirror-registry tarball URL. Pin a versioned URL (not 'latest') + mirror_registry_sha256 before customer use."
}

variable "mirror_registry_sha256" {
  type        = string
  default     = ""
  description = "sha256 of the mirror-registry tarball. When set, cloud-init verifies it (supply-chain). Empty = run unverified (rig only)."
}
