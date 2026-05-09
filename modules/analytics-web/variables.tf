variable "environment" {
  description = "Deployment environment: dev, staging, or prod"
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in all resource names (e.g. edp)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the analytics web service runs"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS task placement"
  type        = list(string)
}

variable "alb_arn" {
  description = "Existing analytics agent ALB ARN"
  type        = string
}

variable "alb_security_group_id" {
  description = "Existing analytics agent ALB security group ID"
  type        = string
}

variable "analytics_agent_url" {
  description = "Base URL for the existing FastAPI analytics backend, for example http://alb-dns-name"
  type        = string
}

variable "task_cpu" {
  description = "ECS task CPU units"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "ECS task memory in MB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of web tasks to run. Set to 0 to pause the service between sessions."
  type        = number
  default     = 0
}
