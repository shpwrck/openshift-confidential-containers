variable "project_id" {
  type        = number
  description = "Existing Cherry Servers project ID. Both servers go in this project."

  validation {
    condition     = var.project_id > 0
    error_message = "Set project_id to your Cherry Servers project ID."
  }
}

variable "region" {
  type        = string
  description = "Region slug, for example LT-Siauliai. Both servers go in this region so they share its private VLAN."

  validation {
    condition     = !startswith(var.region, "REPLACE")
    error_message = "Replace the example region slug in your tfvars file."
  }
}

variable "node_plan" {
  type        = string
  description = "Plan slug of an AMD EPYC bare-metal server whose board supports SEV-SNP. The trial used an H13SST-G with an EPYC 9124."

  validation {
    condition     = !startswith(var.node_plan, "REPLACE")
    error_message = "Replace the example node plan slug in your tfvars file."
  }
}

variable "node_image" {
  type        = string
  description = "Image slug for the node's original OS, used only for the firmware preflight before OpenShift replaces it."

  validation {
    condition     = !startswith(var.node_image, "REPLACE")
    error_message = "Replace the example node image slug in your tfvars file."
  }
}

variable "helper_plan" {
  type        = string
  description = "Plan slug for the helper. It needs no SEV-SNP, only disk for the mirror and a public uplink."

  validation {
    condition     = !startswith(var.helper_plan, "REPLACE")
    error_message = "Replace the example helper plan slug in your tfvars file."
  }
}

variable "helper_image" {
  type        = string
  description = "Image slug for the helper: RHEL 9 (supported for mirror-registry) or a RHEL 9-family image such as AlmaLinux 9 (the trial's compatibility test)."

  validation {
    condition     = !startswith(var.helper_image, "REPLACE")
    error_message = "Replace the example helper image slug in your tfvars file."
  }
}

variable "ssh_public_key_file" {
  type        = string
  default     = ""
  description = "Public key to register for both servers. Leave empty when ssh_key_ids names existing keys."

  validation {
    condition     = var.ssh_public_key_file == "" || fileexists(pathexpand(var.ssh_public_key_file))
    error_message = "No file at ssh_public_key_file. Point it at your public key, or leave it empty and set ssh_key_ids."
  }
}

variable "ssh_key_ids" {
  type        = set(string)
  default     = []
  description = "Existing Cherry Servers SSH key IDs for both servers, instead of ssh_public_key_file."

  validation {
    condition     = length(var.ssh_key_ids) > 0 || var.ssh_public_key_file != ""
    error_message = "Set ssh_public_key_file or ssh_key_ids."
  }
}

variable "node_hostname" {
  type        = string
  default     = "sno-coco-node"
  description = "Hostname of the node's original OS. Ansible checks it against the provider over SSH."
}

variable "helper_hostname" {
  type        = string
  default     = "sno-coco-helper"
  description = "Hostname of the helper."
}

variable "billing_cycle" {
  type        = string
  default     = "hourly"
  description = "Billing cycle slug for both servers."
}

variable "tags" {
  type        = map(string)
  default     = { purpose = "openshift-confidential-containers" }
  description = "Tags for both servers."
}
