data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  dags_bucket_name = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags"
}

# MWAA polls the dags/ prefix in this bucket every 30 seconds and loads new/changed DAG files.
resource "aws_s3_bucket" "dags" {
  bucket        = local.dags_bucket_name
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "dags" {
  bucket = aws_s3_bucket.dags.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dags" {
  bucket = aws_s3_bucket.dags.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dags" {
  bucket                  = aws_s3_bucket.dags.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudWatch log groups with a retention period to keep costs bounded.
# MWAA writes four separate log streams: scheduler, webserver, worker, dag-processor.
locals {
  mwaa_log_components = toset(["scheduler", "webserver", "worker", "dag-processor"])
}

resource "aws_cloudwatch_log_group" "mwaa" {
  for_each          = local.mwaa_log_components
  name              = "/aws/mwaa/${var.name_prefix}-${var.environment}/${each.key}"
  retention_in_days = var.log_retention_days
}

# MWAA workers need self-referencing ingress to communicate with each other.
resource "aws_security_group" "mwaa" {
  name        = "${var.name_prefix}-${var.environment}-mwaa-sg"
  description = "Security group for MWAA environment"
  vpc_id      = var.vpc_id

  ingress {
    description = "MWAA worker-to-worker communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${var.environment}-mwaa-sg" }
}

# MWAA environment. Note: first apply takes 20-30 minutes for AWS to provision Airflow.
resource "aws_mwaa_environment" "this" {
  name              = "${var.name_prefix}-${var.environment}-mwaa"
  airflow_version   = var.airflow_version
  environment_class = var.mwaa_environment_class

  dag_s3_path        = "dags/"
  source_bucket_arn  = aws_s3_bucket.dags.arn
  execution_role_arn = var.mwaa_role_arn
  kms_key            = var.kms_key_arn

  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    subnet_ids         = var.private_subnet_ids
  }

  logging_configuration {
    dag_processing_logs { enabled = true; log_level = "INFO" }
    scheduler_logs      { enabled = true; log_level = "INFO" }
    task_logs           { enabled = true; log_level = "INFO" }
    webserver_logs      { enabled = true; log_level = "INFO" }
    worker_logs         { enabled = true; log_level = "INFO" }
  }

  airflow_configuration_options = {
    "core.load_examples"              = "false"
    "core.dag_file_processor_timeout" = "120"
  }

  depends_on = [
    aws_s3_bucket_versioning.dags,
    aws_cloudwatch_log_group.mwaa,
  ]
}
