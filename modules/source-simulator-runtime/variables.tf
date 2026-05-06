variable "environment" {
  description = "Deployment environment name: dev, staging, or prod."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the simulator task runs."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Fargate simulator tasks."
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "Security group ID attached to the source RDS instance."
  type        = string
}

variable "rds_endpoint" {
  description = "Source RDS PostgreSQL endpoint."
  type        = string
}

variable "ssm_db_password_path" {
  description = "SSM SecureString parameter path that stores the RDS password."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the SSM database password."
  type        = string
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "ecommerce"
}

variable "db_username" {
  description = "PostgreSQL database username."
  type        = string
  default     = "postgres"
}
