variable "environment" {
  description = "Deployment environment: dev, staging, or prod"
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in all resource names (e.g. edp)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the networking module"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS task placement"
  type        = list(string)
}

variable "analytics_agent_url" {
  description = "HTTP base URL for the existing analytics agent API"
  type        = string
}

variable "allowed_channels" {
  description = "Comma-separated Slack channel allowlist. Leave empty to let the gateway decide from runtime config."
  type        = string
  default     = ""
}

variable "task_cpu" {
  description = "ECS task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "ECS task memory in MB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of gateway tasks to run. Defaults to 0 so infra can be created before image and token values exist."
  type        = number
  default     = 0
}
