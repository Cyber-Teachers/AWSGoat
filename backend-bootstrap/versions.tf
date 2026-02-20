terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }
  # Bootstrap state is stored locally (no backend) so this config can run without existing state storage.
}

provider "aws" {
  region = var.region
}
