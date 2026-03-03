variable "environment" { default = "staging" }
variable "region"      { default = "eu-central-1" }
variable "profile"     { default = "staging-admin" }
variable "vpc_cidr"    { default = "10.20.0.0/16" }
variable "name_prefix" { default = "edp" }

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