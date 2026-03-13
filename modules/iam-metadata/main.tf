data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# KMS key used to encrypt everything on the platform (S3, SSM params, Glue logs, Redshift).
resource "aws_kms_key" "platform" {
  description             = "EDP platform encryption key (${var.environment})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${var.name_prefix}-${var.environment}-platform"
  target_key_id = aws_kms_key.platform.key_id
}

# Glue Data Catalog databases — one per Medallion layer.
resource "aws_glue_catalog_database" "bronze" {
  name        = "${var.name_prefix}_${var.environment}_bronze"
  description = "Bronze layer - raw CDC-ingested data"
}

resource "aws_glue_catalog_database" "silver" {
  name        = "${var.name_prefix}_${var.environment}_silver"
  description = "Silver layer - cleansed and deduplicated data"
}

resource "aws_glue_catalog_database" "gold" {
  name        = "${var.name_prefix}_${var.environment}_gold"
  description = "Gold layer - aggregated analytics-ready data"
}

# IAM Role for Glue PySpark jobs.
data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.name_prefix}-${var.environment}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_data_access" {
  statement {
    sid    = "S3DataLakeAccess"
    effect = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.bronze_bucket_name}", "arn:aws:s3:::${var.bronze_bucket_name}/*",
      "arn:aws:s3:::${var.silver_bucket_name}", "arn:aws:s3:::${var.silver_bucket_name}/*",
      "arn:aws:s3:::${var.gold_bucket_name}", "arn:aws:s3:::${var.gold_bucket_name}/*",
      "arn:aws:s3:::${var.quarantine_bucket_name}", "arn:aws:s3:::${var.quarantine_bucket_name}/*",
      "arn:aws:s3:::${var.glue_scripts_bucket_name}", "arn:aws:s3:::${var.glue_scripts_bucket_name}/*",
    ]
  }

  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.platform.arn]
  }

  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
      "glue:CreateTable", "glue:UpdateTable", "glue:BatchCreatePartition",
      "glue:CreatePartition", "glue:UpdatePartition", "glue:GetPartition", "glue:GetPartitions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "glue_data_access" {
  name   = "${var.name_prefix}-${var.environment}-glue-data-access"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_data_access.json
}

# IAM Role for MWAA (Airflow).
data "aws_iam_policy_document" "mwaa_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["airflow.amazonaws.com", "airflow-env.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mwaa" {
  name               = "${var.name_prefix}-${var.environment}-mwaa-role"
  assume_role_policy = data.aws_iam_policy_document.mwaa_assume_role.json
}

data "aws_iam_policy_document" "mwaa_execution" {
  statement {
    sid    = "DAGsBucketAccess"
    effect = "Allow"
    actions = ["s3:GetObject*", "s3:GetBucket*", "s3:List*"]
    resources = [
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags/*",
    ]
  }

  statement {
    sid    = "AirflowLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "logs:GetLogEvents", "logs:GetLogRecord", "logs:GetLogDelivery",
      "logs:ListLogDeliveries", "logs:DescribeLogGroups",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:airflow-${var.name_prefix}-${var.environment}-*",
    ]
  }

  statement {
    sid       = "AirflowMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid    = "AirflowSQS"
    effect = "Allow"
    actions = [
      "sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl", "sqs:ReceiveMessage", "sqs:SendMessage",
    ]
    resources = ["arn:aws:sqs:${data.aws_region.current.name}:*:airflow-celery-*"]
  }

  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey*", "kms:Encrypt"]
    resources = [aws_kms_key.platform.arn]
  }

  statement {
    sid    = "GlueJobInvoke"
    effect = "Allow"
    actions = [
      "glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns",
      "glue:BatchStopJobRun", "glue:GetJob",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "mwaa_execution" {
  name   = "${var.name_prefix}-${var.environment}-mwaa-execution"
  role   = aws_iam_role.mwaa.id
  policy = data.aws_iam_policy_document.mwaa_execution.json
}

# Airflow reads database passwords from SSM to create RDS and Redshift connections at startup.
data "aws_iam_policy_document" "mwaa_ssm" {
  statement {
    sid    = "ReadPlatformSecrets"
    effect = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/edp/${var.environment}/*",
    ]
  }

  statement {
    sid       = "DecryptWithPlatformKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.platform.arn]
  }
}

resource "aws_iam_role_policy" "mwaa_ssm" {
  name   = "${var.name_prefix}-${var.environment}-mwaa-ssm"
  role   = aws_iam_role.mwaa.id
  policy = data.aws_iam_policy_document.mwaa_ssm.json
}

# IAM Role for Redshift Serverless (Spectrum + Glue Catalog access).
data "aws_iam_policy_document" "redshift_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com", "redshift-serverless.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift" {
  name               = "${var.name_prefix}-${var.environment}-redshift-role"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume_role.json
}

data "aws_iam_policy_document" "redshift_access" {
  statement {
    sid     = "S3SpectrumAccess"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.gold_bucket_name}", "arn:aws:s3:::${var.gold_bucket_name}/*",
      "arn:aws:s3:::${var.silver_bucket_name}", "arn:aws:s3:::${var.silver_bucket_name}/*",
    ]
  }

  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.platform.arn]
  }

  statement {
    sid    = "GlueCatalogRead"
    effect = "Allow"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable",
      "glue:GetTables", "glue:GetPartition", "glue:GetPartitions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "redshift_access" {
  name   = "${var.name_prefix}-${var.environment}-redshift-access"
  role   = aws_iam_role.redshift.id
  policy = data.aws_iam_policy_document.redshift_access.json
}

# SSM Default Host Management Configuration (DHMC).
# Enables account-level auto-registration of EC2 instances as SSM managed nodes.
# AWS registers any instance whose IAM role includes AmazonSSMManagedInstanceCore
# without requiring the SSM agent to call the registration API itself.
#
# The AWSSystemsManagerDefaultEC2InstanceManagementRole service role is created
# automatically by the AWS console when DHMC is first enabled. When enabling via
# Terraform/API, the role is NOT auto-created, so we create it explicitly here.
resource "aws_iam_role" "ssm_default_host_management" {
  name = "AWSSystemsManagerDefaultEC2InstanceManagementRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_default_host_management" {
  role       = aws_iam_role.ssm_default_host_management.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
}

resource "aws_ssm_service_setting" "default_host_management" {
  setting_id    = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:servicesetting/ssm/managed-instance/default-ec2-instance-management-role"
  setting_value = "service-role/AWSSystemsManagerDefaultEC2InstanceManagementRole"

  depends_on = [aws_iam_role.ssm_default_host_management]
}

# DMS service-linked IAM roles. These names are required by AWS DMS and cannot be changed.
# If they already exist in the account, import them before applying:
#   terraform import module.iam_metadata.aws_iam_role.dms_vpc dms-vpc-role
#   terraform import module.iam_metadata.aws_iam_role.dms_cloudwatch dms-cloudwatch-logs-role
data "aws_iam_policy_document" "dms_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dms.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dms_vpc" {
  name               = "dms-vpc-role"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
}

resource "aws_iam_role_policy_attachment" "dms_vpc" {
  role       = aws_iam_role.dms_vpc.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

resource "aws_iam_role" "dms_cloudwatch" {
  name               = "dms-cloudwatch-logs-role"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
}

resource "aws_iam_role_policy_attachment" "dms_cloudwatch" {
  role       = aws_iam_role.dms_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}

resource "aws_iam_role" "dms_s3" {
  name               = "${var.name_prefix}-${var.environment}-dms-s3-role"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
}

data "aws_iam_policy_document" "dms_s3_access" {
  statement {
    sid     = "BronzeS3Write"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.bronze_bucket_name}",
      "arn:aws:s3:::${var.bronze_bucket_name}/*",
    ]
  }

  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.platform.arn]
  }
}

resource "aws_iam_role_policy" "dms_s3_access" {
  name   = "${var.name_prefix}-${var.environment}-dms-s3-access"
  role   = aws_iam_role.dms_s3.id
  policy = data.aws_iam_policy_document.dms_s3_access.json
}

# ── GitHub Actions OIDC ──────────────────────────────────────────────────────
#
# Allows GitHub Actions workflows in the specified repositories to authenticate
# to AWS without any long-lived access keys. Each workflow run receives a
# short-lived token (max 1 hour) scoped to the specific repo and branch.
#
# The OIDC provider is account-scoped (one per AWS account). If dev, staging,
# and prod all run in separate accounts (the recommended setup), set
# create_github_oidc_provider = true for each. If they share one account, set
# it to false for all but the first environment to avoid a duplicate error.
#
# Thumbprints are the SHA-1 fingerprints of GitHub's OIDC TLS certificate chain.
# These are stable and do not need to be updated when GitHub rotates certificates
# because AWS no longer validates thumbprints for actions.githubusercontent.com.

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_github_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# If the OIDC provider already exists in the account (create_github_oidc_provider = false),
# look it up by URL so the trust policy ARN reference still resolves correctly.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # Build one condition value per repo: "repo:{org}/{repo}:*"
  github_sub_conditions = [for repo in var.github_repos : "repo:${var.github_org}/${repo}:*"]
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    # Restricts to workflows running from the specified repositories only.
    # The :* suffix covers all branches, tags, and GitHub Environments.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_sub_conditions
    }

    # Ensures the token audience is the AWS STS endpoint, not a third-party service.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.name_prefix}-${var.environment}-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  description        = "Assumed by GitHub Actions workflows in ${var.github_org} repositories via OIDC"
}

# AdministratorAccess is intentional here. This role runs terraform apply for
# the full platform infrastructure, which requires broad AWS permissions.
# Least-privilege is enforced at the trust layer (OIDC, repo-scoped) rather than
# the permission layer. If the Glue and dbt repos need separate, restricted roles
# in future, create dedicated roles for them and update the workflows accordingly.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
