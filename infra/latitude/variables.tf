variable "auth_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Latitude API token. Prefer the LATITUDESH_AUTH_TOKEN env var over setting this."
}

variable "project" {
  type        = string
  description = "Existing Latitude project id (proj_...)."
}

variable "hostname" {
  type    = string
  default = "coco-snp-rig"
}

variable "plan" {
  type        = string
  description = "Genoa (4th-gen EPYC) bare-metal plan slug. Confirm availability: `lsh plans list`."
  # e.g. one of the m4/f4/rs4 Genoa SKUs — leave to fill after querying the account.
}

variable "site" {
  type        = string
  description = "Metro/site with Genoa availability (e.g. SAO2, ASH, DAL, NYC...). Confirm in dashboard."
}

variable "operating_system" {
  type        = string
  default     = "rocky-10"
  description = "Rung-0 host OS. rocky-10 (RHEL-family, kernel 6.12, SNP-capable) — matches the RHCOS customer node. Or \"ipxe\" to netboot a custom image (set ipxe_url)."
}

variable "ipxe_url" {
  type        = string
  default     = ""
  description = "iPXE boot script URL (custom RHEL/Fedora live/installer) when operating_system=\"ipxe\"."
}

variable "user_data" {
  type        = string
  default     = ""
  description = "Optional cloud-init user-data (install snpguest/qemu, verify kernel post-boot)."
}

variable "ssh_key_ids" {
  type        = list(string)
  default     = []
  description = "Existing Latitude ssh key ids to inject. Or use create_ssh_key + ssh_public_key_path."
}

variable "create_ssh_key" {
  type    = bool
  default = false
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

# --- Air-gap wiring (depends on the bastion module) --------------------------------------
variable "air_gap" {
  type        = bool
  default     = true
  description = "Join the bastion VLAN (and optionally its firewall). false = standalone rung-0 node, no bastion."
}

variable "bastion_state_path" {
  type        = string
  default     = "bastion/terraform.tfstate"
  description = "Path to the bastion module's local state (relative to this module dir; bastion/ is nested here), read for the VLAN + firewall ids when air_gap=true."
}

variable "enforce_latitude_firewall" {
  type        = bool
  default     = false
  description = "Attach the bastion's INBOUND-hardening firewall (SSH/API/ingress from admin_cidr). Off by default so a wrong admin_cidr can't lock you out. (Egress lockdown is host-nftables, not this.)"
}
