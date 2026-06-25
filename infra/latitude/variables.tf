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
  default     = "ipxe"
  description = "\"ipxe\" for the Ubuntu 25.04 netboot path (set ipxe_url too), or a stock OS slug."
}

variable "ipxe_url" {
  type        = string
  default     = ""
  description = "iPXE boot script URL (Ubuntu 25.04 live/installer) when operating_system=\"ipxe\"."
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
