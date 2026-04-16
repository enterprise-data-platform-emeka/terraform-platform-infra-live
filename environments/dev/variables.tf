variable "environment" { default = "dev" }
variable "region"      { default = "eu-central-1" }
variable "profile"     { default = null }
variable "vpc_cidr"    { default = "10.10.0.0/16" }
variable "name_prefix" { default = "edp" }

# Ingestion variables — commented out after Phase 1 CDC run.
# Uncomment when module "ingestion" and bastion are re-enabled.
#
# variable "db_password" {
#   description = "RDS master password. Provide via TF_VAR_db_password env var or secret.tfvars"
#   type        = string
#   sensitive   = true
# }
#
# variable "db_instance_class" {
#   description = "RDS instance class"
#   type        = string
#   default     = "db.t3.micro"
# }
#
# variable "dms_instance_class" {
#   description = "DMS replication instance class"
#   type        = string
#   default     = "dms.t3.medium"
# }
#
# variable "multi_az" {
#   description = "Enable Multi-AZ for RDS and DMS"
#   type        = bool
#   default     = false
# }
#
# variable "deletion_protection" {
#   description = "Enable RDS deletion protection"
#   type        = bool
#   default     = false
# }

# ── Serving (commented out: module "serving" is disabled) ────────────────────
# Uncomment when re-enabling Redshift Serverless in main.tf.
#
# variable "redshift_admin_password" {
#   description = "Admin password for Redshift Serverless namespace. Provide via TF_VAR_redshift_admin_password env var or secret.tfvars"
#   type        = string
#   sensitive   = true
# }
