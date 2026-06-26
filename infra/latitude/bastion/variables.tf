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

# --- Firewall lockdown ------------------------------------------------------------------
variable "admin_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Admin source CIDR allowed to reach the node (SSH/API). FILL: tighten before customer use."
}

# --- mirror-registry bootstrap ----------------------------------------------------------
variable "mirror_init_user" {
  type        = string
  default     = "init"
  description = "Initial mirror-registry (quay) admin username."
}

variable "mirror_init_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Initial mirror-registry admin password. FILL via TF_VAR_mirror_init_password (do not commit)."
}

variable "mirror_root" {
  type        = string
  default     = "/opt/mirror"
  description = "Persistent on-disk root for the quay data + oc-mirror workspace (the cacheable bottleneck)."
}
