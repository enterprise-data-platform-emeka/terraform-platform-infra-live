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

variable "bronze_bucket_name" {
  description = "Bronze S3 bucket name — agent reads metadata/dbt/* and writes metadata/agent-audit/*"
  type        = string
}

variable "gold_bucket_name" {
  description = "Gold S3 bucket name — agent reads Gold Parquet files for Athena queries"
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
