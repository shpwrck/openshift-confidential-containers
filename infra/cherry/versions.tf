terraform {
  required_version = ">= 1.9"

  required_providers {
    cherryservers = {
      source  = "cherryservers/cherryservers"
      version = "1.6.1"
    }
  }

  # State holds server identities and addresses: keep it in COCO_STATE_DIR,
  # outside the checkout (see docs/cherry-servers.md).
  #   terraform -chdir=infra/cherry init -backend-config="path=$COCO_STATE_DIR/cherry.tfstate"
  backend "local" {}
}

# Reads the API key from CHERRY_API_KEY.
provider "cherryservers" {}
