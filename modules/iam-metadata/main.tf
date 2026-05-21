# -----------------------------------------------------------------------------
# Module purpose
# -----------------------------------------------------------------------------
# This module creates the shared security and metadata foundation for one
# environment. It owns the platform encryption key, the Glue Catalog databases,
# and the IAM roles used by the data platform services.
#
# Read the file by service boundary:
#   1. Platform encryption and Glue databases
#   2. Glue PySpark jobs
#   3. MWAA Airflow
#   4. Redshift Serverless
#   5. Systems Manager default EC2 management
#   6. DMS ingestion roles

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# 1. Platform encryption and Glue databases
# -----------------------------------------------------------------------------

# One KMS key protects the environment-level platform data and operational
# metadata. Other services receive narrow permissions to use this key only when
# they need to read or write encrypted platform resources.
resource "aws_kms_key" "platform" {
  description             = "EDP platform encryption key (${var.environment})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${var.name_prefix}-${var.environment}-platform"
  target_key_id = aws_kms_key.platform.key_id
}

# Glue Data Catalog databases are split by Medallion layer so jobs and query
# engines can target Bronze, Silver, and Gold data separately.
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

# -----------------------------------------------------------------------------
# 2. Glue PySpark jobs
# -----------------------------------------------------------------------------

# Glue assumes this role when running ETL and dbt helper jobs. The attached
# policies let those jobs move data through the Medallion layers, update the Glue
# Catalog, write Athena results, and publish data quality metrics.
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

# Data movement permissions for Glue jobs. These jobs can read and write only
# the platform buckets that take part in the pipeline, plus the script bucket
# that stores job code.
data "aws_iam_policy_document" "glue_data_access" {
  statement {
    sid     = "S3DataLakeAccess"
    effect  = "Allow"
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
    sid       = "KMSAccess"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.platform.arn]
  }

  # Glue jobs create and update tables and partitions as files land in S3.
  # dbt-athena also needs table-version operations when it replaces views.
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
      "glue:CreateTable", "glue:UpdateTable", "glue:BatchCreatePartition",
      "glue:CreatePartition", "glue:UpdatePartition", "glue:GetPartition", "glue:GetPartitions",
      "glue:GetTableVersion", "glue:GetTableVersions", "glue:DeleteTableVersion", "glue:BatchDeleteTableVersion",
    ]
    resources = ["*"]
  }

  # run_dbt.py starts Athena queries from inside a Glue job, then reads query
  # status and results for freshness checks, dbt runs, and dbt tests.
  statement {
    sid    = "AthenaQueryExecution"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution", "athena:StopQueryExecution",
      "athena:GetQueryExecution", "athena:GetQueryResults",
      "athena:GetWorkGroup",
    ]
    resources = ["*"]
  }

  # Athena stores query output in the dedicated results bucket. Glue needs this
  # access only because dbt-athena writes and reads result files there.
  statement {
    sid     = "AthenaResultsS3Access"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.athena_results_bucket_name}",
      "arn:aws:s3:::${var.athena_results_bucket_name}/*",
    ]
  }

  # Jobs publish freshness signals that monitoring alarms and dashboards read.
  statement {
    sid       = "DataFreshnessMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["EDP/DataFreshness"]
    }
  }

  # Jobs publish row-count and quality signals during pipeline validation.
  statement {
    sid       = "DataQualityMetricsWrite"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["EDP/DataQuality"]
    }
  }

  # Validation code reads recent quality metrics to compare the current run with
  # the expected state.
  statement {
    sid       = "DataQualityMetricsRead"
    effect    = "Allow"
    actions   = ["cloudwatch:GetMetricStatistics"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "glue_data_access" {
  name   = "${var.name_prefix}-${var.environment}-glue-data-access"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_data_access.json
}

# -----------------------------------------------------------------------------
# 3. MWAA Airflow
# -----------------------------------------------------------------------------

# MWAA assumes this role for the Airflow scheduler, workers, and webserver. The
# role mirrors the Step Functions pipeline path so Airflow can run the same
# end-to-end workflow during final validation.
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

# Airflow needs to read DAG files and packaged dbt artifacts from the MWAA S3
# bucket, invoke the approved Glue and crawler steps, run dbt through Athena, and
# write Airflow logs and metrics.
data "aws_iam_policy_document" "mwaa_execution" {
  # DAG, requirements, plugins, and dbt project files are stored in this bucket.
  statement {
    sid     = "DAGsBucketAccess"
    effect  = "Allow"
    actions = ["s3:GetObject*", "s3:GetBucket*", "s3:List*"]
    resources = [
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags/*",
    ]
  }

  # MWAA publishes environment health and task metrics to the Airflow service.
  statement {
    sid       = "AirflowPublishMetrics"
    effect    = "Allow"
    actions   = ["airflow:PublishMetrics"]
    resources = ["arn:aws:airflow:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:environment/${var.name_prefix}-${var.environment}-mwaa"]
  }

  # Airflow task logs go to CloudWatch Logs. The resource patterns cover both
  # AWS-created airflow-* log groups and the platform /aws/mwaa/ groups.
  statement {
    sid    = "AirflowLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "logs:GetLogEvents", "logs:GetLogRecord", "logs:GetLogDelivery",
      "logs:ListLogDeliveries", "logs:DescribeLogGroups",
    ]
    resources = [
      # MWAA creates log groups named airflow-{env-name}-{component}.
      # The wildcard covers both our pre-created /aws/mwaa/ groups and the
      # airflow-edp-dev-mwaa-* groups MWAA creates internally.
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:airflow-${var.name_prefix}-${var.environment}-*",
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/mwaa/${var.name_prefix}-${var.environment}/*",
    ]
  }

  # Airflow emits operational metrics for scheduler and worker health.
  statement {
    sid       = "AirflowMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  # MWAA uses SQS internally for Celery task dispatch between scheduler and
  # workers. The queue name is created by the managed service.
  statement {
    sid    = "AirflowSQS"
    effect = "Allow"
    actions = [
      "sqs:ChangeMessageVisibility", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl", "sqs:ReceiveMessage", "sqs:SendMessage",
    ]
    resources = ["arn:aws:sqs:${data.aws_region.current.name}:*:airflow-celery-*"]
  }

  # MWAA needs KMS access for its own managed SQS queue as well as platform data.
  # The wildcard is intentional because the AWS-managed SQS key ARN is not known
  # during Terraform planning.
  statement {
    sid     = "KMSAccess"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey*", "kms:Encrypt"]
    # "*" is required because MWAA's internal Celery SQS queue uses the
    # AWS-managed SQS key (alias/aws/sqs), whose ARN is not known at plan time.
    # Scoping to the platform key alone causes kms:GenerateDataKey failures
    # when the scheduler sends tasks to that queue.
    resources = ["*"]
  }

  # The Airflow DAG starts and monitors the same Glue jobs used by the default
  # Step Functions path.
  statement {
    sid    = "GlueJobInvoke"
    effect = "Allow"
    actions = [
      "glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns",
      "glue:BatchStopJobRun", "glue:GetJob",
    ]
    resources = ["*"]
  }

  # Airflow starts the crawler after Silver data lands so the Glue Catalog sees
  # the latest table and partition metadata.
  statement {
    sid    = "GlueCrawlerInvoke"
    effect = "Allow"
    actions = [
      "glue:StartCrawler", "glue:StopCrawler",
      "glue:GetCrawler", "glue:GetCrawlerMetrics",
    ]
    resources = ["*"]
  }

  # dbt-athena needs catalog read and write operations while building Gold views
  # and tables from the Airflow path.
  statement {
    sid    = "GlueCatalogReadWrite"
    effect = "Allow"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases",
      "glue:GetTable", "glue:GetTables",
      "glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable",
      "glue:GetPartition", "glue:GetPartitions",
      "glue:CreatePartition", "glue:BatchCreatePartition",
      "glue:UpdatePartition", "glue:DeletePartition",
      "glue:GetTableVersion", "glue:GetTableVersions",
      "glue:DeleteTableVersion", "glue:BatchDeleteTableVersion",
    ]
    resources = ["*"]
  }

  # Airflow runs dbt through Athena and checks query status and results.
  statement {
    sid    = "AthenaQueryExecution"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution", "athena:StopQueryExecution",
      "athena:GetQueryExecution", "athena:GetQueryResults",
      "athena:GetWorkGroup", "athena:ListWorkGroups",
    ]
    resources = ["*"]
  }

  # Airflow reads Silver data, writes Gold data, and uses the Athena results
  # bucket while dbt runs.
  statement {
    sid    = "DataLakeS3Access"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:GetBucketLocation", "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-silver",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-silver/*",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-gold",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-gold/*",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-athena-results",
      "arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-athena-results/*",
    ]
  }
}

resource "aws_iam_role_policy" "mwaa_execution" {
  name   = "${var.name_prefix}-${var.environment}-mwaa-execution"
  role   = aws_iam_role.mwaa.id
  policy = data.aws_iam_policy_document.mwaa_execution.json
}

# Airflow reads connection values from SSM Parameter Store at startup so secrets
# are not stored in DAG code or Terraform variables.
data "aws_iam_policy_document" "mwaa_ssm" {
  statement {
    sid     = "ReadPlatformSecrets"
    effect  = "Allow"
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

# -----------------------------------------------------------------------------
# 4. Redshift Serverless
# -----------------------------------------------------------------------------

# Redshift assumes this role when Spectrum reads external Silver and Gold data
# through the Glue Catalog.
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

# Redshift gets read-only access to curated data and the catalog metadata needed
# to expose external schemas. It does not get write access to the data lake.
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
    sid       = "KMSAccess"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
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

# -----------------------------------------------------------------------------
# 5. Systems Manager default EC2 management
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# 6. DMS ingestion roles
# -----------------------------------------------------------------------------

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

# DMS assumes this role to write change data capture files into the Bronze
# landing bucket. It does not need access to Silver or Gold.
resource "aws_iam_role" "dms_s3" {
  name               = "${var.name_prefix}-${var.environment}-dms-s3-role"
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
}

data "aws_iam_policy_document" "dms_s3_access" {
  # DMS writes raw change events into Bronze and may delete its own intermediate
  # objects during task reloads.
  statement {
    sid     = "BronzeS3Write"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.bronze_bucket_name}",
      "arn:aws:s3:::${var.bronze_bucket_name}/*",
    ]
  }

  # Bronze objects are encrypted with the platform key, so DMS needs data-key
  # generation for writes and decrypt for task-level read checks.
  statement {
    sid       = "KMSAccess"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.platform.arn]
  }
}

resource "aws_iam_role_policy" "dms_s3_access" {
  name   = "${var.name_prefix}-${var.environment}-dms-s3-access"
  role   = aws_iam_role.dms_s3.id
  policy = data.aws_iam_policy_document.dms_s3_access.json
}
