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

variable "vpc_cidr" {
  description = "VPC CIDR block, used to restrict Redshift ingress to traffic from within the VPC"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs from the networking module. Redshift Serverless requires at least two subnets in different AZs."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN from the iam-metadata module, used to encrypt Redshift storage"
  type        = string
}

variable "redshift_role_arn" {
  description = "Redshift IAM role ARN from the iam-metadata module, grants Redshift access to S3 and the Glue catalog"
  type        = string
}

variable "redshift_admin_username" {
  description = "Admin username for the Redshift Serverless namespace"
  type        = string
  default     = "admin"
}

variable "redshift_admin_password" {
  description = "Admin password for the Redshift Serverless namespace. Provide via TF_VAR_redshift_admin_password or secret.tfvars. Never commit this."
  type        = string
  sensitive   = true
}

variable "redshift_db_name" {
  description = "Name of the default database created in the Redshift namespace"
  type        = string
  default     = "edp"
}

variable "base_capacity_rpus" {
  description = "Base capacity in RPUs (Redshift Processing Units). Minimum is 8. Higher values give more compute for complex queries."
  type        = number
  default     = 8
}
