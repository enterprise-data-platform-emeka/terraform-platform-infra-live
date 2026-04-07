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
  description = "List of private subnet IDs from the networking module. MWAA requires at least two subnets in different AZs."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN from the iam-metadata module, used to encrypt the DAGs bucket and MWAA environment variables"
  type        = string
}

variable "mwaa_role_arn" {
  description = "MWAA execution role ARN from the iam-metadata module"
  type        = string
}

variable "airflow_version" {
  description = "Apache Airflow version to use. Check AWS docs for supported versions."
  type        = string
  default     = "2.9.2"
}

variable "mwaa_environment_class" {
  description = "MWAA environment class controls the size of the scheduler and worker instances. mw1.small is the smallest and cheapest option."
  type        = string
  default     = "mw1.small"
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs from MWAA components. After this period, logs are automatically deleted."
  type        = number
  default     = 30
}

variable "nat_gateway_id" {
  description = "NAT Gateway ID from the networking module. Passed so the MWAA environment depends on NAT routing being fully ready before creation starts."
  type        = string
  default     = ""
}

variable "force_destroy" {
  description = "If true, allows the DAGs S3 bucket to be deleted even when it contains files. Set to true for dev, false for staging and prod."
  type        = bool
  default     = false
}
