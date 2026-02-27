data "aws_caller_identity" "current" {}

locals {
  bronze_bucket         = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-bronze"
  silver_bucket         = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-silver"
  gold_bucket           = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-gold"
  quarantine_bucket     = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-quarantine"
  athena_results_bucket = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-athena-results"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
    AccountID   = data.aws_caller_identity.current.account_id
  }
}

######################################################
# Buckets
######################################################

resource "aws_s3_bucket" "bronze" {
  bucket        = local.bronze_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket" "silver" {
  bucket        = local.silver_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket" "gold" {
  bucket        = local.gold_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket" "quarantine" {
  bucket        = local.quarantine_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket" "athena_results" {
  bucket        = local.athena_results_bucket
  force_destroy = var.force_destroy
}

######################################################
# Encryption
######################################################

resource "aws_s3_bucket_server_side_encryption_configuration" "all" {
  for_each = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    quarantine     = aws_s3_bucket.quarantine.id
    athena_results = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

######################################################
# Versioning
######################################################

resource "aws_s3_bucket_versioning" "all" {
  for_each = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    quarantine     = aws_s3_bucket.quarantine.id
    athena_results = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

######################################################
# Public Access Block
######################################################

resource "aws_s3_bucket_public_access_block" "all" {
  for_each = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    quarantine     = aws_s3_bucket.quarantine.id
    athena_results = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}