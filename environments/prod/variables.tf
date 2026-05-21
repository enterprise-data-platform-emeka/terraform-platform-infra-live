# -----------------------------------------------------------------------------
# Prod input variables
# -----------------------------------------------------------------------------
# Defines the configuration switches and sensitive values used by the prod stack.

variable "environment" { default = "prod" }
variable "region" { default = "eu-central-1" }
variable "profile" { default = null }
variable "vpc_cidr" { default = "10.30.0.0/16" }
variable "name_prefix" { default = "edp" }

variable "alert_email" {
  description = "Email address for CloudWatch alarm SNS notifications. Optional: omit to skip the email subscription. Provide via TF_VAR_alert_email."
  type        = string
  default     = null
}

variable "enable_cdc_simulator" {
  description = "Create the CDC simulator ECS task runner for this environment."
  type        = bool
  default     = false
}

variable "enable_step_functions" {
  description = "Create the Step Functions orchestrator."
  type        = bool
  default     = false
}

variable "enable_mwaa" {
  description = "Create the MWAA Airflow orchestrator."
  type        = bool
  default     = true
}

variable "enable_analytics_agent" {
  description = "Create the Analytics Agent ECS service."
  type        = bool
  default     = true
}

variable "enable_slack_mcp_gateway" {
  description = "Create the optional Slack MCP gateway ECS service."
  type        = bool
  default     = false
}

variable "slack_mcp_allowed_channels" {
  description = "Comma-separated Slack channel allowlist for the gateway, for example analytics-agent-demo."
  type        = string
  default     = "analytics-agent-demo"
}

variable "slack_mcp_desired_count" {
  description = "Number of Slack MCP gateway tasks to run when enabled."
  type        = number
  default     = 0
}

variable "enable_serving" {
  description = "Create the optional Redshift Serverless serving layer for BI/query workloads."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Ingestion
# -----------------------------------------------------------------------------

variable "db_password" {
  description = "RDS master password. Required when enable_cdc_simulator=true."
  type        = string
  sensitive   = true
  default     = null
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
  default     = true
}

variable "deletion_protection" {
  description = "Enable RDS deletion protection"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Serving
# -----------------------------------------------------------------------------

variable "redshift_admin_password" {
  description = "Admin password for Redshift Serverless namespace. Required when enable_serving=true."
  type        = string
  sensitive   = true
  default     = null
}

variable "redshift_base_capacity_rpus" {
  description = "Base compute capacity for Redshift Serverless in RPUs (Redshift Processing Units). Minimum is 8."
  type        = number
  default     = 16
}
