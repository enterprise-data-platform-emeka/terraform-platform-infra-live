data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  silver_jobs = [
    "dim_customer",
    "dim_product",
    "fact_orders",
    "fact_order_items",
    "fact_payments",
    "fact_shipments",
  ]
}

# ── Glue Python Shell job: run_dbt ───────────────────────────────────────────
# Runs dbt against Athena to produce Gold tables. The script (run_dbt.py) is
# uploaded to S3 by the platform-glue-jobs deploy workflow alongside the six
# Silver PySpark jobs. It is triggered by Step Functions after the Silver
# crawler completes.
#
# dbt-core and dbt-athena-community are installed at job startup via
# --additional-python-modules. This adds ~2-3 min to the first run on a cold
# container but requires no pre-built image or custom packaging.

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

# ── IAM role for Step Functions ───────────────────────────────────────────────
# Step Functions needs permission to start Glue job runs and wait for them,
# and to start and poll the Glue Crawler. It also writes execution logs to
# CloudWatch for debugging.

data "aws_iam_policy_document" "sfn_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name_prefix}-${var.environment}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json
}

data "aws_iam_policy_document" "sfn_execution" {
  statement {
    sid    = "GlueJobControl"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "GlueCrawlerControl"
    effect = "Allow"
    actions = [
      "glue:StartCrawler",
      "glue:GetCrawler",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn_execution" {
  name   = "${var.name_prefix}-${var.environment}-sfn-execution"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn_execution.json
}

# ── CloudWatch Log Group for Step Functions executions ────────────────────────

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.name_prefix}-${var.environment}-pipeline"
  retention_in_days = 7
}

# ── Step Functions state machine ──────────────────────────────────────────────
# Pipeline:
#   6 Silver Glue jobs (parallel) -> Silver crawler -> dbt Glue job
#
# All Glue job steps use the .sync integration pattern, which means Step
# Functions starts the job and waits for it to reach a terminal state before
# moving to the next state. No polling loops needed for jobs.
#
# The Silver Crawler does not have a .sync integration, so it uses a
# StartCrawler -> Wait -> GetCrawler -> Choice polling loop instead.

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.name_prefix}-${var.environment}-pipeline"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "EDP data pipeline: 6 Silver Glue jobs -> Silver crawler -> dbt Gold"
    StartAt = "RunSilverJobsParallel"

    States = {
      RunSilverJobsParallel = {
        Type    = "Parallel"
        Comment = "Run all six Silver Glue jobs in parallel. All must succeed before the crawler runs."
        Branches = [
          for job_name in local.silver_jobs : {
            StartAt = "silver_${job_name}"
            States = {
              "silver_${job_name}" = {
                Type     = "Task"
                Resource = "arn:aws:states:::glue:startJobRun.sync"
                Parameters = {
                  JobName = "${var.name_prefix}-${var.environment}-${job_name}"
                }
                End = true
              }
            }
          }
        ]
        Next = "SilverJobsComplete"
      }

      SilverJobsComplete = {
        Type       = "Pass"
        Comment    = "Discard the parallel job results array. The crawler polling loop requires a plain object as input, not an array."
        Result     = {}
        ResultPath = "$"
        Next       = "StartSilverCrawler"
      }

      StartSilverCrawler = {
        Type     = "Task"
        Comment  = "Start the Glue Crawler that registers Silver table schemas in the Glue Data Catalog."
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = "${var.name_prefix}-${var.environment}-silver-crawler"
        }
        ResultPath = null
        Next       = "WaitForCrawler"
      }

      WaitForCrawler = {
        Type    = "Wait"
        Comment = "Wait 30 seconds before polling crawler status."
        Seconds = 30
        Next    = "CheckCrawlerStatus"
      }

      CheckCrawlerStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = {
          Name = "${var.name_prefix}-${var.environment}-silver-crawler"
        }
        ResultPath = "$.CrawlerResult"
        Next       = "IsCrawlerDone"
      }

      IsCrawlerDone = {
        Type    = "Choice"
        Comment = "READY means the crawler finished successfully. RUNNING means still in progress. Anything else is a failure."
        Choices = [
          {
            Variable     = "$.CrawlerResult.Crawler.State"
            StringEquals = "READY"
            Next         = "RunDbt"
          },
          {
            Variable     = "$.CrawlerResult.Crawler.State"
            StringEquals = "RUNNING"
            Next         = "WaitForCrawler"
          },
          {
            Variable     = "$.CrawlerResult.Crawler.State"
            StringEquals = "STOPPING"
            Next         = "WaitForCrawler"
          }
        ]
        Default = "CrawlerFailed"
      }

      RunDbt = {
        Type     = "Task"
        Comment  = "Run dbt to produce Gold tables via Athena, then run dbt test."
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = "${var.name_prefix}-${var.environment}-run-dbt"
        }
        Next = "PipelineComplete"
      }

      PipelineComplete = {
        Type    = "Succeed"
        Comment = "All Silver and Gold steps completed successfully."
      }

      CrawlerFailed = {
        Type  = "Fail"
        Error = "CrawlerFailed"
        Cause = "The Silver Glue Crawler ended in an unexpected state. Check the Glue console for details."
      }
    }
  })

  logging_configuration {
    level                  = "ERROR"
    include_execution_data = false
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
  }

  depends_on = [aws_iam_role_policy.sfn_execution]
}
