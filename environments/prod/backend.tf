terraform {
  backend "s3" {
    bucket         = "enterprise-data-platform-tfstate-prod"
    key            = "platform-infra-live/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "enterprise-data-platform-tf-lock-prod"
    profile        = "prod-admin"
    encrypt        = true
  }
}
