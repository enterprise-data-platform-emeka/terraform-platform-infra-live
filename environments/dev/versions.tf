# -----------------------------------------------------------------------------
# Terraform version constraints
# -----------------------------------------------------------------------------
# Keeps local and CI plans on the same Terraform and AWS provider major versions.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
