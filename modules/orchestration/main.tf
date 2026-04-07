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
      # AES256 (SSE-S3) is used here instead of customer-managed KMS because
      # MWAA requires the bucket encryption key to match the environment's
      # kms_key setting. Since MWAA uses service-managed encryption (no
      # kms_key specified), the bucket must also use service-managed
      # encryption. The bucket holds DAG code and requirements.txt — not
      # sensitive pipeline data — so SSE-S3 is appropriate.
      sse_algorithm = "AES256"
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

# On first deploy, Terraform uploads placeholder files so the MWAA environment
# can be created. After that, the application CI/CD pipelines own these artifacts:
#   requirements.txt — platform-orchestration-mwaa-airflow deploy workflow
#   plugins.zip      — platform-dbt-analytics deploy workflow
#
# Both pipelines call 'aws mwaa update-environment' with the new S3 object version
# when content changes. Terraform ignores these files after the first upload, which
# prevents a spurious 35-minute MWAA environment update on every infrastructure apply.
resource "aws_s3_object" "requirements" {
  bucket       = aws_s3_bucket.dags.id
  key          = "requirements.txt"
  content      = "# placeholder — managed by platform-orchestration-mwaa-airflow CI\n"
  content_type = "text/plain"

  lifecycle {
    # After first creation the application CI owns this file.
    # Terraform must not overwrite it or installed packages regress to an empty list.
    ignore_changes = [content, etag]
  }
}

resource "aws_s3_object" "plugins" {
  bucket         = aws_s3_bucket.dags.id
  key            = "plugins.zip"
  # Minimal valid empty ZIP (22-byte end-of-central-directory record).
  # The platform-dbt-analytics CI replaces this with the real dbt project on its
  # first deploy, then calls 'aws mwaa update-environment' to apply it to workers.
  content_base64 = "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA=="
  content_type   = "application/zip"

  lifecycle {
    # After first creation the platform-dbt-analytics CI owns this file.
    ignore_changes = [content_base64, etag]
  }
}

# MWAA environment. Note: first apply takes 20-30 minutes for AWS to provision Airflow.
resource "aws_mwaa_environment" "this" {
  name              = "${var.name_prefix}-${var.environment}-mwaa"
  airflow_version        = var.airflow_version
  environment_class      = var.mwaa_environment_class
  webserver_access_mode  = "PUBLIC_ONLY"

  dag_s3_path                  = "dags/"
  requirements_s3_path         = aws_s3_object.requirements.key
  requirements_s3_object_version = aws_s3_object.requirements.version_id
  plugins_s3_path              = aws_s3_object.plugins.key
  plugins_s3_object_version    = aws_s3_object.plugins.version_id
  source_bucket_arn    = aws_s3_bucket.dags.arn
  execution_role_arn   = var.mwaa_role_arn
  # kms_key is intentionally omitted. MWAA uses service-managed encryption for
  # its internal SQS queues and metadata. Customer-managed KMS requires the key
  # policy to explicitly grant access to sqs.amazonaws.com and logs.amazonaws.com
  # service principals, which the platform KMS key does not do. The actual pipeline
  # data (S3 Bronze/Silver/Gold) still uses customer-managed KMS.

  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    subnet_ids         = var.private_subnet_ids
  }

  logging_configuration {
    dag_processing_logs {
      enabled   = true
      log_level = "INFO"
    }
    scheduler_logs {
      enabled   = true
      log_level = "INFO"
    }
    task_logs {
      enabled   = true
      log_level = "INFO"
    }
    webserver_logs {
      enabled   = true
      log_level = "INFO"
    }
    worker_logs {
      enabled   = true
      log_level = "INFO"
    }
  }

  airflow_configuration_options = {
    "core.load_examples"              = "false"
    "core.dag_file_processor_timeout" = "120"
    # The default celery.operation_timeout is 1 second. On MWAA, the first
    # apply_async call to SQS can exceed 1 second (cold TCP connection, DNS
    # resolution). When it does, all dispatched tasks fail immediately with
    # "Was the task killed externally?" at queued state. 15 seconds gives SQS
    # enough headroom for cold-start latency without masking real hangs.
    "celery.operation_timeout"        = "15"
  }

  # Referencing nat_gateway_id in a tag creates an implicit Terraform dependency
  # so MWAA environment creation waits for the NAT Gateway to be fully routing.
  # Without this, workers cannot reach PyPI during startup and the environment
  # fails with INCORRECT_CONFIGURATION.
  tags = {
    nat_gateway = var.nat_gateway_id != "" ? var.nat_gateway_id : "none"
  }

  depends_on = [
    aws_s3_bucket_versioning.dags,
    aws_cloudwatch_log_group.mwaa,
    aws_s3_object.requirements,
    aws_s3_object.plugins,
  ]

  lifecycle {
    # plugins_s3_object_version and requirements_s3_object_version are managed
    # by the application CI/CD pipelines via 'aws mwaa update-environment'.
    # Terraform sets the initial version at environment creation time, then ignores
    # subsequent changes so that a routine infrastructure apply never triggers a
    # 35-minute MWAA environment update.
    ignore_changes = [
      plugins_s3_object_version,
      requirements_s3_object_version,
    ]
  }
}
