data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  dags_bucket_name = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags"
}

# ── Glue Python Shell job: run_dbt ───────────────────────────────────────────
# This job is required by the MWAA DAG's gold_dbt_run task. The script
# (run_dbt.py) is uploaded to S3 by the platform-glue-jobs deploy workflow
# alongside the six Silver PySpark jobs. It installs dbt-core and
# dbt-athena-community at job startup via --additional-python-modules.

resource "aws_glue_job" "run_dbt" {
  name     = "${var.name_prefix}-${var.environment}-run-dbt"
  role_arn = var.glue_role_arn

  command {
    name            = "pythonshell"
    script_location = "s3://${var.glue_scripts_bucket_name}/glue-scripts/run_dbt.py"
    python_version  = "3.9"
  }

  default_arguments = {
    "--additional-python-modules" = "dbt-core==1.8.7,dbt-athena-community==1.8.3"
    "--DBT_TARGET"                = var.environment
    "--BRONZE_BUCKET"             = var.bronze_bucket_name
    "--ATHENA_RESULTS_BUCKET"     = var.athena_results_bucket
    "--ATHENA_WORKGROUP"          = "${var.name_prefix}-${var.environment}-workgroup"
    "--DBT_ATHENA_SCHEMA"         = "${var.name_prefix}_${var.environment}_gold"
    "--AWS_DEFAULT_REGION"        = data.aws_region.current.name
  }

  glue_version = "3.0"
  max_capacity = 0.0625
  timeout      = 30
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

# requirements.txt is infrastructure. Terraform owns and manages it fully.
# MWAA's Python runtime environment (which packages are installed) is part of
# the infrastructure definition, the same way an EC2 AMI or user_data is.
#
# Terraform uploads requirements.txt when MWAA is first created so the
# environment comes up with all packages already installed. When content
# changes, Terraform detects it (via etag drift), uploads a new S3 version,
# and the aws_mwaa_environment resource picks up the new version_id and
# triggers an update. No application CI ever calls update-environment.
#
# IMPORTANT: when Python packages need to change, update this file
# (modules/orchestration/requirements.txt) and run terraform apply.
# Also update platform-orchestration-mwaa-airflow/requirements.txt so local
# development stays in sync.
#
# plugins.zip: Permanent empty placeholder. The dbt project is not in
# plugins.zip. It is synced to s3://{mwaa-bucket}/dbt/platform-dbt-analytics/
# by the platform-dbt-analytics deploy workflow and downloaded at task runtime.
resource "aws_s3_object" "requirements" {
  bucket       = aws_s3_bucket.dags.id
  key          = "requirements.txt"
  source       = "${path.module}/requirements.txt"
  etag         = filemd5("${path.module}/requirements.txt")
  content_type = "text/plain"
}

resource "aws_s3_object" "plugins" {
  bucket         = aws_s3_bucket.dags.id
  key            = "plugins.zip"
  # Minimal valid empty ZIP (22-byte end-of-central-directory record).
  # This is a permanent placeholder. The dbt project is delivered via S3 sync,
  # not plugins.zip. This file is never updated after initial creation.
  content_base64 = "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA=="
  content_type   = "application/zip"

  lifecycle {
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
    # plugins_s3_object_version: plugins.zip is a permanent empty placeholder.
    # It never changes, so Terraform ignores drift on this field to prevent a
    # spurious 35-minute MWAA update if the version ID ever diverges.
    #
    # requirements_s3_object_version is NOT ignored. Terraform tracks it fully.
    # When requirements.txt content changes, Terraform uploads a new S3 version
    # and updates this field, which triggers a MWAA environment update (~35 min).
    # That is the correct and expected behaviour for a package change.
    ignore_changes = [
      plugins_s3_object_version,
    ]
  }
}
