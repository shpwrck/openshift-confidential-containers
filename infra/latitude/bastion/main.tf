# Persistent air-gap bastion for the disconnected SNO rig.
#
# This module is the LONG-LIVED half of the rig. It stands up:
#   - a private virtual network (VLAN) the disposable SNP node joins,
#   - a bastion bare-metal host running the Red Hat `mirror-registry` (quay),
#   - the egress-lockdown firewall ruleset the SNP node attaches to.
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
# The node's only sanctioned path to the outside world is to the bastion across this VLAN.
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
  operating_system = var.operating_system # reuse the proven ubuntu_26_04 slug; cloud-init adds podman
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
  # VERIFY: Latitude's user_data API expects base64-encoded content; the provider passes it
  # through. If a first apply shows the cloud-init not running, drop the base64encode().
  content = base64encode(templatefile("${path.module}/cloud-init/mirror-registry.yaml", {
    quay_hostname = var.hostname
    init_user     = var.mirror_init_user
    init_password = var.mirror_init_password
    mirror_root   = var.mirror_root
  }))
}

# --- Egress-lockdown firewall (assigned to the SNP node, in the node module) --------------
# Latitude firewalls are deny-by-default for unmatched traffic. THE DIRECTION SEMANTICS
# (does a rule with to=<bastion> actually constrain the node's EGRESS, or only inbound?)
# ARE NOT DOCUMENTED — treat this as a `# VERIFY` to confirm on first provision (runbook
# Phase 1 has the curl probe). If Latitude proves inbound-only, fall back to a host-level
# nftables default-deny-egress (runbook documents the snippet). Do not assume this enforces
# the air gap until the probe confirms it.
#
# Ruleset intent: permit only node<->bastion (mirror + DNS) and the admin SSH/API surface;
# everything else falls through to deny. The node attaches this via firewall_assignment.
resource "latitudesh_firewall" "node_egress_lockdown" {
  project = var.project
  name    = "coco-node-airgap-lockdown"

  # node <-> bastion: mirror-registry (quay) over its private IP
  rules {
    from     = "${latitudesh_server.bastion.primary_ipv4}/32"
    to       = "Any"
    protocol = "TCP"
    port     = "8443" # VERIFY: mirror-registry quay port (default 8443)
  }
  # node <-> bastion: DNS (the bastion can also serve DNS for the air gap)
  rules {
    from     = "${latitudesh_server.bastion.primary_ipv4}/32"
    to       = "Any"
    protocol = "TCP"
    port     = "53"
  }
  # admin reachability into the node — SSH + k8s API + MCS + ingress.
  # VERIFY/FILL: tighten `from` to your admin CIDR instead of Any before customer use.
  rules {
    from     = var.admin_cidr
    to       = "Any"
    protocol = "TCP"
    port     = "22"
  }
  rules {
    from     = var.admin_cidr
    to       = "Any"
    protocol = "TCP"
    port     = "6443"
  }
}
