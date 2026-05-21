# -----------------------------------------------------------------------------
# Dev input variables
# -----------------------------------------------------------------------------
# Defines the configuration switches and sensitive values used by the dev stack.

variable "environment" { default = "dev" }
variable "region" { default = "eu-central-1" }
variable "profile" { default = null }
variable "vpc_cidr" { default = "10.10.0.0/16" }
variable "name_prefix" { default = "edp" }

variable "alert_email" {
  description = "Email address for CloudWatch alarm SNS notifications. Optional: omit to skip the email subscription. Provide via TF_VAR_alert_email."
  type        = string
  default     = null
}

variable "enable_slack_mcp_gateway" {
  description = "Create the optional Slack MCP gateway ECS service."
  type        = bool
  default     = false
}

variable "enable_step_functions" {
  description = "Create the Step Functions orchestrator."
  type        = bool
  default     = true
}

variable "enable_mwaa" {
  description = "Create the MWAA Airflow orchestrator."
  type        = bool
  default     = false
}

variable "enable_analytics_agent" {
  description = "Create the Analytics Agent ECS service."
  type        = bool
  default     = true
}

variable "enable_analytics_web" {
  description = "Create the optional custom HTML analytics web dashboard ECS service."
  type        = bool
  default     = false
}

variable "analytics_web_desired_count" {
  description = "Number of custom analytics web dashboard tasks to run when enabled."
  type        = number
  default     = 0
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

variable "enable_cdc_simulator" {
  description = "Create dev ingestion infrastructure and the CDC simulator ECS task runner."
  type        = bool
  default     = false
}

variable "db_password" {
  description = "RDS master password. Required when enable_cdc_simulator=true."
  type        = string
  sensitive   = true
  default     = null
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
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

# -----------------------------------------------------------------------------
# Serving
# -----------------------------------------------------------------------------

variable "enable_serving" {
  description = "Create the optional Redshift Serverless serving layer for BI/query workloads."
  type        = bool
  default     = false
}

variable "redshift_admin_password" {
  description = "Admin password for Redshift Serverless namespace. Required when enable_serving=true."
  type        = string
  sensitive   = true
  default     = null
}
