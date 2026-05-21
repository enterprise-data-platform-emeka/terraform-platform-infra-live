# -----------------------------------------------------------------------------
# AWS provider
# -----------------------------------------------------------------------------
# Uses the dev AWS SSO profile and applies common tags to all taggable resources.

provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = "EnterpriseDataPlatform"
    }
  }
}
