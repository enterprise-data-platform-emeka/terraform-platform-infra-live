# -----------------------------------------------------------------------------
# Remote state backend
# -----------------------------------------------------------------------------
# Stores dev Terraform state in the bootstrap-managed S3 bucket with DynamoDB
# locking so local and CI runs cannot update state at the same time.

terraform {
  backend "s3" {
    bucket         = "enterprise-data-platform-tfstate-dev"
    key            = "dev/platform-infra-live/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "enterprise-data-platform-tf-lock-dev"
    profile        = "dev-admin"
    encrypt        = true
  }
}
