data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  dags_bucket_name = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags"
}

# ── DAGs S3 bucket ────────────────────────────────────────────────────────────
#
# MWAA reads Airflow DAG Python files from this S3 bucket. The bucket must
# exist before the MWAA environment is created. MWAA polls the dags/ prefix
# every 30 seconds and loads any new or changed DAG files automatically.

resource "aws_s3_bucket" "dags" {
  bucket        = local.dags_bucket_name
  force_destroy = var.force_destroy

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

resource "aws_s3_bucket_versioning" "dags" {
  bucket = aws_s3_bucket.dags.id

  versioning_configuration {
    status = "Enabled"
  }
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
  bucket = aws_s3_bucket.dags.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── CloudWatch log groups ─────────────────────────────────────────────────────
#
# MWAA writes logs from four Airflow components to separate CloudWatch log
# groups. I create these in advance so I can control the retention period.
# Without a retention period, CloudWatch keeps logs forever and costs grow
# unbounded over time.

resource "aws_cloudwatch_log_group" "mwaa_scheduler" {
  name              = "/aws/mwaa/${var.name_prefix}-${var.environment}/scheduler"
  retention_in_days = var.log_retention_days

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

resource "aws_cloudwatch_log_group" "mwaa_webserver" {
  name              = "/aws/mwaa/${var.name_prefix}-${var.environment}/webserver"
  retention_in_days = var.log_retention_days

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

resource "aws_cloudwatch_log_group" "mwaa_worker" {
  name              = "/aws/mwaa/${var.name_prefix}-${var.environment}/worker"
  retention_in_days = var.log_retention_days

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

resource "aws_cloudwatch_log_group" "mwaa_dag_processor" {
  name              = "/aws/mwaa/${var.name_prefix}-${var.environment}/dag-processor"
  retention_in_days = var.log_retention_days

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

# ── Security group for MWAA ───────────────────────────────────────────────────
#
# MWAA workers need to communicate with each other (self-referencing rule),
# and need outbound access to reach S3 (via VPC endpoint) and AWS APIs.

resource "aws_security_group" "mwaa" {
  name        = "${var.name_prefix}-${var.environment}-mwaa-sg"
  description = "Security group for MWAA environment"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow MWAA workers to communicate with each other"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound (S3 via VPC endpoint, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.name_prefix}-${var.environment}-mwaa-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

# ── MWAA environment ──────────────────────────────────────────────────────────
#
# MWAA (Amazon Managed Workflows for Apache Airflow) is a fully managed
# Airflow service. AWS handles the Airflow installation, upgrades, and
# scaling of the scheduler and workers.
#
# The environment takes 20-30 minutes to create on first apply.

resource "aws_mwaa_environment" "this" {
  name              = "${var.name_prefix}-${var.environment}-mwaa"
  airflow_version   = var.airflow_version
  environment_class = var.mwaa_environment_class

  dag_s3_path        = "dags/"
  source_bucket_arn  = aws_s3_bucket.dags.arn
  execution_role_arn = var.mwaa_role_arn

  kms_key = var.kms_key_arn

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
    "core.load_examples"       = "false"
    "core.dag_file_processor_timeout" = "120"
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }

  depends_on = [
    aws_s3_bucket_versioning.dags,
    aws_cloudwatch_log_group.mwaa_scheduler,
    aws_cloudwatch_log_group.mwaa_webserver,
    aws_cloudwatch_log_group.mwaa_worker,
    aws_cloudwatch_log_group.mwaa_dag_processor,
  ]
}
