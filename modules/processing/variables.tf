variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
}

variable "name_prefix" {
  description = "Short prefix for all resource names, for example edp"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the networking module"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs from the networking module"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN from the iam-metadata module, used to encrypt Glue logs, bookmarks, and S3 output"
  type        = string
}

variable "athena_results_bucket" {
  description = "Athena results bucket name from the data-lake module"
  type        = string
}
