# Offline: nothing is ordered and no API key is needed.
#   terraform -chdir=infra/cherry init -backend=false && terraform -chdir=infra/cherry test

mock_provider "cherryservers" {}

variables {
  project_id   = 123456
  region       = "LT-Siauliai"
  node_plan    = "fixture-amd-plan"
  node_image   = "fixture-node-image"
  helper_plan  = "fixture-helper-plan"
  helper_image = "fixture-helper-image"
  ssh_key_ids  = ["42"]
}

run "orders_both_servers_without_user_data" {
  command = plan

  # With user data, Cherry installs neither the SSH key nor the private VLAN.
  assert {
    condition     = cherryservers_server.helper.user_data == null && cherryservers_server.node.user_data == null
    error_message = "Neither server may be ordered with user data."
  }
  assert {
    condition = alltrue([
      for server in [cherryservers_server.node, cherryservers_server.helper] :
      server.project_id == 123456 && server.region == "LT-Siauliai" && server.ssh_key_ids == toset(["42"])
    ])
    error_message = "Both servers must share the project, region and SSH key."
  }
  assert {
    condition     = length(cherryservers_ssh_key.rig) == 0
    error_message = "No key is registered when existing key IDs are given."
  }
}

run "registers_the_public_key_when_no_ids_are_given" {
  command = plan

  variables {
    ssh_key_ids         = []
    ssh_public_key_file = "tests/fixture-key.pub"
  }

  assert {
    condition     = length(cherryservers_ssh_key.rig) == 1 && startswith(cherryservers_ssh_key.rig[0].public_key, "ssh-ed25519 ")
    error_message = "The public key file must be registered."
  }
}

run "the_untouched_example_values_are_refused" {
  command = plan

  # The placeholders from terraform.tfvars.example.
  variables {
    project_id          = 0
    region              = "REPLACE_WITH_REGION_SLUG"
    node_plan           = "REPLACE_WITH_AMD_SNP_PLAN_SLUG"
    node_image          = "REPLACE_WITH_NODE_IMAGE_SLUG"
    helper_plan         = "REPLACE_WITH_HELPER_PLAN_SLUG"
    helper_image        = "REPLACE_WITH_RHEL9_FAMILY_IMAGE_SLUG"
    ssh_public_key_file = "/path/outside/checkout/rig-ssh-key.pub"
    ssh_key_ids         = []
  }

  expect_failures = [
    var.project_id,
    var.region,
    var.node_plan,
    var.node_image,
    var.helper_plan,
    var.helper_image,
    var.ssh_public_key_file,
  ]
}

run "rig_values_carry_the_assigned_addresses" {
  module {
    source = "./modules/rig_values"
  }

  variables {
    servers = {
      node = {
        id       = "1025551"
        hostname = "sno-coco-node"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.3", cidr = "84.32.48.3/25", vlan_id = 0 },
          { type = "private-ip", address_family = 4, address = "10.191.48.7", cidr = "10.191.48.7/24", vlan_id = 2738 },
        ]
      }
      helper = {
        id       = "1025601"
        hostname = "sno-coco-helper"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.9", cidr = "84.32.48.9/25", vlan_id = 0 },
          { type = "private-ip", address_family = 4, address = "10.191.48.8", cidr = "10.191.48.0/24", vlan_id = 2738 },
        ]
      }
    }
  }

  assert {
    condition = output.rig_values == {
      project_id          = "123456"
      node_id             = "1025551"
      node_hostname       = "sno-coco-node"
      node_public_ipv4    = "84.32.48.3"
      node_private_ipv4   = "10.191.48.7"
      helper_id           = "1025601"
      helper_hostname     = "sno-coco-helper"
      helper_public_ipv4  = "84.32.48.9"
      helper_private_ipv4 = "10.191.48.8"
      private_network     = "10.191.48.0/24"
      vlan_tag            = "2738"
    }
    error_message = "rig_values does not match the assigned addresses: ${jsonencode(output.rig_values)}"
  }
  assert {
    condition     = output.node_public_ipv4 == "84.32.48.3" && output.helper_public_ipv4 == "84.32.48.9"
    error_message = "Public addresses are wrong."
  }
}

run "a_missing_vlan_tag_is_reported_as_null" {
  module {
    source = "./modules/rig_values"
  }

  variables {
    servers = {
      node = {
        id       = "1025551"
        hostname = "sno-coco-node"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.3", cidr = "84.32.48.3/25" },
          { type = "private-ip", address_family = 4, address = "10.191.48.7", cidr = "10.191.48.7/24" },
        ]
      }
      helper = {
        id       = "1025601"
        hostname = "sno-coco-helper"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.9", cidr = "84.32.48.9/25" },
          { type = "private-ip", address_family = 4, address = "10.191.48.8", cidr = "10.191.48.8/24" },
        ]
      }
    }
  }

  assert {
    condition     = output.rig_values.vlan_tag == null
    error_message = "Without a tag from the API there is no tag to report; the rig file takes the one seen on the node."
  }
}

run "servers_on_different_switches_are_refused" {
  command = plan

  module {
    source = "./modules/rig_values"
  }

  variables {
    servers = {
      node = {
        id       = "1025551"
        hostname = "sno-coco-node"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.3", cidr = "84.32.48.3/25", vlan_id = 0 },
          { type = "private-ip", address_family = 4, address = "10.191.48.7", cidr = "10.191.48.7/24", vlan_id = 2738 },
        ]
      }
      helper = {
        id       = "1025601"
        hostname = "sno-coco-helper"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.49.9", cidr = "84.32.49.9/25", vlan_id = 0 },
          { type = "private-ip", address_family = 4, address = "10.191.52.8", cidr = "10.191.52.8/24", vlan_id = 2911 },
        ]
      }
    }
  }

  expect_failures = [output.rig_values]
}

run "a_server_without_a_private_address_is_refused" {
  command = plan

  module {
    source = "./modules/rig_values"
  }

  variables {
    servers = {
      node = {
        id       = "1025551"
        hostname = "sno-coco-node"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.3", cidr = "84.32.48.3/25", vlan_id = 0 },
        ]
      }
      helper = {
        id       = "1025601"
        hostname = "sno-coco-helper"
        ip_addresses = [
          { type = "primary-ip", address_family = 4, address = "84.32.48.9", cidr = "84.32.48.9/25", vlan_id = 0 },
          { type = "private-ip", address_family = 4, address = "10.191.48.8", cidr = "10.191.48.8/24", vlan_id = 2738 },
        ]
      }
    }
  }

  expect_failures = [output.rig_values]
}
