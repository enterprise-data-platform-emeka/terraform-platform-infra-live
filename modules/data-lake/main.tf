data "aws_caller_identity" "current" {}

locals {
  buckets = {
    bronze         = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-bronze"
    silver         = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-silver"
    gold           = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-gold"
    quarantine     = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-quarantine"
    athena_results = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-athena-results"
    glue_scripts   = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-glue-scripts"
  }
}

resource "aws_s3_bucket" "this" {
  for_each      = local.buckets
  bucket        = each.value
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
