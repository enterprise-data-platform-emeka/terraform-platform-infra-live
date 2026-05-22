# -----------------------------------------------------------------------------
# Analytics Agent input variables
# -----------------------------------------------------------------------------
# Receives ECS sizing, network IDs, data access targets, and optional email config.

variable "environment" {
  description = "Deployment environment: dev, staging, or prod"
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in all resource names (e.g. edp)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the networking module"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS task placement"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB (must span at least 2 AZs)"
  type        = list(string)
}

variable "ses_sender_email" {
  description = "SES-verified sender address for PDF email reports. Leave empty to disable the send-report feature."
  type        = string
  default     = ""
}

variable "bronze_bucket_name" {
  description = "Bronze S3 bucket name. The agent reads metadata/dbt/* and writes metadata/agent-audit/*."
  type        = string
}

variable "gold_bucket_name" {
  description = "Gold S3 bucket name. The agent reads Gold Parquet files for Athena queries."
  type        = string
}

variable "athena_results_bucket" {
  description = "Athena query results bucket name from the data-lake module"
  type        = string
}

variable "kms_key_arn" {
  description = "Platform KMS key ARN from the iam-metadata module"
  type        = string
}

variable "glue_gold_database" {
  description = "Glue Catalog database name for the Gold layer from the iam-metadata module"
  type        = string
}

variable "silver_bucket_name" {
  description = "Name of the Silver S3 bucket. Athena reads Silver Parquet files when resolving Gold views."
  type        = string
}

variable "glue_silver_database" {
  description = "Glue Catalog database name for the Silver layer. Athena needs this to resolve Gold views that reference Silver tables."
  type        = string
}

variable "claude_provider" {
  description = "Claude authentication mode for the agent. Use anthropic_api_key for the existing SSM API key path, or aws_claude_platform for IAM/SigV4 through Claude Platform on AWS."
  type        = string
  default     = "anthropic_api_key"

  validation {
    condition     = contains(["anthropic_api_key", "aws_claude_platform"], var.claude_provider)
    error_message = "claude_provider must be anthropic_api_key or aws_claude_platform."
  }
}

variable "claude_workspace_id_ssm_parameter" {
  description = "SSM Parameter Store path that contains the Claude Platform on AWS workspace ID. Leave empty to use /edp/{environment}/claude/workspace_id."
  type        = string
  default     = ""
}

variable "claude_inference_geo" {
  description = "Inference geography for Claude Platform on AWS requests. Use us to pin inference to US data centers, or global to allow global routing."
  type        = string
  default     = "us"

  validation {
    condition     = contains(["us", "global"], var.claude_inference_geo)
    error_message = "claude_inference_geo must be us or global."
  }
}

variable "task_cpu" {
  description = "ECS task CPU units (512 = 0.5 vCPU)"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "ECS task memory in MB"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of ECS service tasks to run. Set to 0 to pause the service between test sessions without destroying it."
  type        = number
  default     = 1
}
