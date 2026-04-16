variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
}

variable "name_prefix" {
  description = "Short prefix for all resource names, for example edp"
  type        = string
}

variable "bronze_bucket_name" {
  description = "Bronze S3 bucket name. The dbt Glue job downloads the dbt project from here and uploads audit artifacts back to it."
  type        = string
}

variable "athena_results_bucket" {
  description = "Athena results bucket name. Passed to the dbt Glue job as the dbt s3_staging_dir."
  type        = string
}

variable "glue_scripts_bucket_name" {
  description = "Glue scripts S3 bucket name. The run_dbt.py script is uploaded here by the platform-glue-jobs deploy workflow."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN from the iam-metadata module. Used to encrypt Step Functions execution logs."
  type        = string
}
