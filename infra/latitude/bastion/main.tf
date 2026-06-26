# Persistent air-gap bastion for the disconnected SNO rig.
#
# This module is the LONG-LIVED half of the rig. It stands up:
#   - a private virtual network (VLAN) with real L3 (static private IPs assigned in cloud-init),
#   - a bastion bare-metal host running the Red Hat `mirror-registry` (quay) under a DNS name
#     mapped to its PRIVATE IP (so the node's mirror pull validates the cert SAN),
#   - an INBOUND-hardening firewall the SNP node attaches to (egress lockdown is host nftables).
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
  required_providers {
    latitudesh = {
      source  = "latitudesh/latitudesh"
      version = "~> 3.3" # resolved to v3.3.0
    }
  }
}

provider "latitudesh" {
  auth_token = var.auth_token != "" ? var.auth_token : null
}

# --- Private network the bastion + SNP node share ----------------------------------------
# L2 membership only at this layer; static L3 addressing is assigned in cloud-init / agent-config
# so the node's only sanctioned egress path is to the bastion's private IP across this VLAN.
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
  project          = var.project
  hostname         = var.hostname
  plan             = var.plan
  site             = var.site
  operating_system = var.operating_system # rocky-10 (RHEL-family): mirror-registry + podman validated
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

# --- Inbound hardening firewall for the SNP node -----------------------------------------
# SCOPE: this firewall hardens INBOUND traffic to the node. It is NOT the air-gap egress
# mechanism — Latitude firewall egress direction is undocumented and likely inbound-only, so
# the node's EGRESS lockdown is enforced host-side with nftables (default-deny output except
# to the bastion; see runbook Phase 1). Shipping egress-looking rules here would be a false
# control, so we don't.
#
# Coherent allowlist: only the admin surface reaches the node inbound (deny-by-default for the
# rest). `from` = admin source CIDR (set consciously, no 0.0.0.0/0 default); the node does not
# need any inbound from the bastion (the node initiates the mirror pull, it does not serve it).
# The node attaches this via firewall_assignment (opt-in: var.enforce_latitude_firewall).
resource "latitudesh_firewall" "node_inbound" {
  project = var.project
  name    = "coco-node-inbound-hardening"

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
