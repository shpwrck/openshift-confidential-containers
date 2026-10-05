# Persistent air-gap bastion for the disconnected SNO rig.
#
# This module is the LONG-LIVED half of the rig. It stands up:
#   - a private virtual network (VLAN) with real L3 (static private IPs assigned in cloud-init),
#   - a bastion bare-metal host running the Red Hat `mirror-registry` (quay) under a DNS name
#     mapped to its PRIVATE IP (so the node's mirror pull validates the cert SAN),
#   - a firewall API object the SNP node can optionally reference; enforcement is unverified.
#
# Why a separate module / separate state from infra/latitude/ (the SNP node):
# mirroring is the ~1-2h bottleneck and is CACHEABLE. Keeping the mirror workspace on
# THIS host's disk means we pay that cost once and it survives every `terraform destroy`
# of the disposable node. Lifecycle: bring the bastion up once for the engagement spike,
# cycle the SNP node underneath it freely, tear the bastion down only at the very end.
#
# The SNP node module reads this module's outputs via terraform_remote_state
# (../bastion/terraform.tfstate) — so apply THIS module first.

terraform {
  required_version = ">= 1.13, < 2.0"
  required_providers {
    latitudesh = {
      source  = "latitudesh/latitudesh"
      version = "= 4.6.0" # reviewed provider schema; locked per module
    }
  }
}

provider "latitudesh" {
  auth_token = var.auth_token != "" ? var.auth_token : null
}

# --- Private network the bastion + SNP node share ----------------------------------------
# L2 membership only at this layer; static L3 addressing is assigned in cloud-init / agent-config.
# VLAN membership does not establish egress isolation.
resource "latitudesh_virtual_network" "rig" {
  project     = var.project
  site        = var.site
  description = "coco-rig-airgap"
  tags        = var.tags
}

# --- Bastion host ------------------------------------------------------------------------
# Cheapest available metal SKU — it does NOT need SEV-SNP (it is not a confidential worker),
# only disk for the mirror cache + internet egress to populate it. Pick the smallest plan
# with enough disk via `lsh plans list`; leave the slug to var.plan (do not invent one).
resource "latitudesh_server" "bastion" {
  allow_reinstall  = false # reinstall is an explicit, journaled Ansible operation
  project          = var.project
  hostname         = var.hostname
  plan             = var.plan
  site             = var.site
  operating_system = var.operating_system # Rocky 9 lab baseline; see supported-host distinction in README.
  billing          = var.billing          # "hourly" while engaged; "monthly" is cheaper if it runs for weeks
  ssh_keys         = var.ssh_key_ids

  # Reusable user-data object (latitudesh_server.user_data takes the user_data RESOURCE ID,
  # not raw content). Content lives in latitudesh_user_data.bastion below.
  user_data = latitudesh_user_data.bastion.id
}

resource "latitudesh_vlan_assignment" "bastion" {
  server_id          = latitudesh_server.bastion.id
  virtual_network_id = latitudesh_virtual_network.rig.id
}

# --- Bastion bootstrap (cloud-init) ------------------------------------------------------
# Installs podman + Red Hat mirror-registry, lays out the persistent mirror cache, and
# surfaces the generated CA + pull credential to known paths. See cloud-init/mirror-registry.yaml.
resource "latitudesh_user_data" "bastion" {
  description = "coco-bastion-mirror-registry"
  # Latitude's user_data API expects base64-encoded content; the provider passes it through.
  content = base64encode(templatefile("${path.module}/cloud-init/mirror-registry.yaml", {
    bastion_ssh_user       = var.bastion_ssh_user
    init_user              = var.mirror_init_user
    mirror_root            = var.mirror_root
    mirror_registry_url    = var.mirror_registry_url
    mirror_registry_sha256 = var.mirror_registry_sha256
    # private-VLAN L3 + DNS identity (fixes the cosmetic-VLAN / x509-SAN defects)
    bastion_vlan_ip       = var.bastion_vlan_ip
    vlan_subnet           = var.vlan_subnet
    vlan_prefix           = var.vlan_prefix
    vlan_parent_interface = var.vlan_parent_interface
    vlan_vid              = latitudesh_virtual_network.rig.vid
    registry_dns_name     = var.registry_dns_name
    # NB: the admin password is NOT passed in — it is generated on the bastion (0600).
  }))
}

# --- Firewall API object: intended inbound rules, not verified enforcement ---------------
# Latitude documents a host-installed UFW/iptables agent with inbound/outbound rules.
# This module creates only the rule object; node assignment installs no agent.
# Provider 4.6.0 preserves an automatic SSH rule outside Terraform state, so admin_cidr
# does not imply exclusive SSH access. Keep the resource identity for existing rigs.
# Agent/RHCOS compatibility, effective rules and traffic must be checked separately;
# see README.md. Egress acceptance also requires tests in the relevant network contexts.
resource "latitudesh_firewall" "node_inbound" {
  project = var.project
  name    = var.firewall_name

  rules {
    from     = var.admin_cidr
    to       = "ANY"
    protocol = "TCP"
    port     = "22" # SSH
  }
  rules {
    from     = var.admin_cidr
    to       = "ANY"
    protocol = "TCP"
    port     = "6443" # k8s API
  }
  rules {
    from     = var.admin_cidr
    to       = "ANY"
    protocol = "TCP"
    port     = "443" # ingress / console
  }
}
