variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "name_prefix" {
  description = "Global naming prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for security groups and subnet groups"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for RDS and DMS"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN for RDS storage encryption"
  type        = string
}

variable "bronze_bucket_name" {
  description = "Name of the Bronze S3 bucket (DMS CDC target)"
  type        = string
}

variable "dms_s3_role_arn" {
  description = "IAM role ARN that grants DMS write access to the Bronze bucket"
  type        = string
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL source database"
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Database name on the RDS instance"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the RDS PostgreSQL instance"
  type        = string
  default     = "dbadmin"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "dms_instance_class" {
  description = "DMS replication instance class"
  type        = string
  default     = "dms.t3.medium"
}

variable "multi_az" {
  description = "Enable Multi-AZ for RDS and DMS (true for prod)"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection on RDS (true for prod)"
  type        = bool
  default     = false
}
