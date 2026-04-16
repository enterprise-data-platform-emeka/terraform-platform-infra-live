variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "name_prefix" {
  description = "Global naming prefix"
  type        = string
}

variable "bronze_bucket_name" {
  description = "Name of the Bronze S3 bucket"
  type        = string
}

variable "silver_bucket_name" {
  description = "Name of the Silver S3 bucket"
  type        = string
}

variable "gold_bucket_name" {
  description = "Name of the Gold S3 bucket"
  type        = string
}

variable "quarantine_bucket_name" {
  description = "Name of the Quarantine S3 bucket"
  type        = string
}

variable "glue_scripts_bucket_name" {
  description = "Name of the Glue scripts S3 bucket"
  type        = string
}

variable "athena_results_bucket_name" {
  description = "Name of the Athena results S3 bucket. Granted to the Glue role so dbt-athena can write query results."
  type        = string
}
