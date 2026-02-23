######################################################
# DATA LAKE MODULE — ENTERPRISE MEDALLION STORAGE
######################################################

######################################################
# Current AWS Account (for global uniqueness safety)
######################################################

# Even though we are adding "emeka" to ensure uniqueness,
# we still fetch the account ID for tagging and audit clarity.

data "aws_caller_identity" "current" {}

######################################################
# Local Naming Convention
######################################################

# We add "emeka" to avoid global namespace collision.
# S3 bucket names are globally unique across all AWS accounts.

locals {
  bronze_bucket         = "edp-emeka-${var.environment}-bronze"
  silver_bucket         = "edp-emeka-${var.environment}-silver"
  gold_bucket           = "edp-emeka-${var.environment}-gold"
  quarantine_bucket     = "edp-emeka-${var.environment}-quarantine"
  athena_results_bucket = "edp-emeka-${var.environment}-athena-results"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "Emeka"
    Project     = "EnterpriseDataPlatform"
    AccountID   = data.aws_caller_identity.current.account_id
  }
}

######################################################
# BRONZE BUCKET — RAW IMMUTABLE CDC EVENTS
######################################################

# Purpose:
# - Append-only ingestion
# - Audit-grade storage
# - No transformations allowed here

resource "aws_s3_bucket" "bronze" {
  bucket        = local.bronze_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.bronze_bucket
    Layer = "Bronze"
  })
}

######################################################
# SILVER BUCKET — STRUCTURED & CLEANED DATA
######################################################

# Purpose:
# - Cleaned datasets
# - Parquet files
# - Partitioned storage
# - Queryable via Athena

resource "aws_s3_bucket" "silver" {
  bucket        = local.silver_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.silver_bucket
    Layer = "Silver"
  })
}

######################################################
# GOLD BUCKET — BUSINESS AGGREGATES
######################################################

# Purpose:
# - Denormalized datasets
# - Business KPIs
# - BI consumption
# - Redshift COPY source

resource "aws_s3_bucket" "gold" {
  bucket        = local.gold_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.gold_bucket
    Layer = "Gold"
  })
}

######################################################
# QUARANTINE BUCKET — INVALID DATA
######################################################

# Purpose:
# - Schema failures
# - Corrupted records
# - Data quality rejections
# - Never mixed with Bronze

resource "aws_s3_bucket" "quarantine" {
  bucket        = local.quarantine_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.quarantine_bucket
    Layer = "Quarantine"
  })
}

######################################################
# ATHENA RESULTS BUCKET
######################################################

# Purpose:
# - Controlled query output location
# - Enforced by Athena Workgroup
# - Prevents analysts writing results to random buckets

resource "aws_s3_bucket" "athena_results" {
  bucket        = local.athena_results_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.athena_results_bucket
    Layer = "QueryResults"
  })
}

######################################################
# ENCRYPTION — REQUIRED FOR ALL BUCKETS
######################################################

# Why:
# Enterprise rule: all data must be encrypted at rest.

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
# VERSIONING — ENABLE RECOVERY & IMMUTABILITY
######################################################

# Why:
# - Protects against accidental overwrite
# - Enables rollback
# - Supports compliance and audit recovery

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
# PUBLIC ACCESS BLOCK — ENTERPRISE SAFETY CONTROL
######################################################

# Why:
# Public buckets are major security incidents.
# This ensures zero public exposure.

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