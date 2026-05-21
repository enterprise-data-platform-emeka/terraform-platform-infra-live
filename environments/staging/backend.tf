# -----------------------------------------------------------------------------
# Remote state backend
# -----------------------------------------------------------------------------
# Stores staging Terraform state in the bootstrap-managed S3 bucket with DynamoDB
# locking so local and CI runs cannot update state at the same time.

terraform {
  backend "s3" {
    bucket         = "enterprise-data-platform-tfstate-staging"
    key            = "staging/platform-infra-live/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "enterprise-data-platform-tf-lock-staging"
    profile        = "staging-admin"
    encrypt        = true
  }
}
