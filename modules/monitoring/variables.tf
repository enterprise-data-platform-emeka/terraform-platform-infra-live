variable "environment" {
  description = "Deployment environment name (dev, staging, prod)"
  type        = string
}

variable "name_prefix" {
  description = "Short name prefix used on all resource names"
  type        = string
}

variable "alert_email" {
  description = "Email address that receives SNS alarm notifications. Optional — when null, the SNS topic is created but no email subscriber is added. Set via TF_VAR_alert_email."
  type        = string
  default     = null
}

variable "state_machine_name" {
  description = "Step Functions state machine name for the pipeline failure alarm"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name for Analytics Agent health alarms"
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name for Analytics Agent health alarms"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch ApplicationELB metric dimensions"
  type        = string
}
