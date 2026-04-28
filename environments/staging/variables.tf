variable "environment" { default = "staging" }
variable "region"      { default = "eu-central-1" }
variable "profile"     { default = null }
variable "vpc_cidr"    { default = "10.20.0.0/16" }
variable "name_prefix" { default = "edp" }

variable "alert_email" {
  description = "Email address for CloudWatch alarm SNS notifications. Provide via TF_VAR_alert_email."
  type        = string
}

# ── Ingestion ────────────────────────────────────────────────────────────────

variable "db_password" {
  description = "RDS master password. Provide via TF_VAR_db_password env var or secret.tfvars"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.small"
}

variable "dms_instance_class" {
  description = "DMS replication instance class"
  type        = string
  default     = "dms.t3.medium"
}

variable "multi_az" {
  description = "Enable Multi-AZ for RDS and DMS"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable RDS deletion protection"
  type        = bool
  default     = false
}

# ── Serving ──────────────────────────────────────────────────────────────────

variable "redshift_admin_password" {
  description = "Admin password for Redshift Serverless namespace. Provide via TF_VAR_redshift_admin_password env var or secret.tfvars"
  type        = string
  sensitive   = true
}
