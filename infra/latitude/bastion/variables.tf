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
  default     = "rocky-10"
  description = "Bastion OS — RHEL-family (Rocky 10): mirror-registry + podman (AppStream) validated here, NetworkManager network stack, SELinux enforcing. `lsh` OS slugs: rocky-10 / almalinux-10."
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

# --- Private VLAN L3 (the real air gap) -------------------------------------------------
# The SNP node reaches the mirror ONLY over this private segment. The registry is served under
# a DNS name mapped to the bastion's private IP, so quay's cert SAN matches what the node dials.
variable "vlan_subnet" {
  type        = string
  default     = "192.168.66.0/24"
  description = "Private CIDR for the rig VLAN (informational + node egress nftables allow-scope)."
}

variable "vlan_prefix" {
  type        = number
  default     = 24
  description = "Prefix length for the VLAN addresses (must agree with vlan_subnet)."
}

variable "bastion_vlan_ip" {
  type        = string
  default     = "192.168.66.10"
  description = "Static private IP assigned to the bastion on the VLAN (the mirror's address)."
}

variable "node_vlan_ip" {
  type        = string
  default     = "192.168.66.11"
  description = "Static private IP the SNP node should use on the VLAN (consumed in agent-config nmstate / NM)."
}

variable "vlan_parent_interface" {
  type        = string
  default     = "auto"
  description = "VLAN parent NIC. \"auto\" (default) detects the cabled, un-addressed, non-USB physical NIC (the private port). Override with an explicit name if detection picks wrong. Hardware-bound."
}

variable "registry_dns_name" {
  type        = string
  default     = "mirror.rig.local"
  description = "DNS name the mirror is served under (quay cert SAN). Resolves to bastion_vlan_ip via /etc/hosts on bastion + node."
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
  description = "Versioned HTTPS mirror-registry tarball URL, verified alongside mirror_registry_sha256. Required; there is no latest fallback."
  validation {
    condition     = startswith(var.mirror_registry_url, "https://") && !can(regex("(?i)(^|/)latest(/|$)", var.mirror_registry_url))
    error_message = "Provide a versioned HTTPS mirror-registry URL; latest is not a reproducible bootstrap input."
  }
}

variable "mirror_registry_sha256" {
  type        = string
  description = "Published SHA-256 of the selected mirror-registry tarball. Required and always checked before extraction."
  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", var.mirror_registry_sha256))
    error_message = "Provide the selected mirror-registry tarball's verified 64-character SHA-256."
  }
}
