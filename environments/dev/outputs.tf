# ── Monitoring outputs ────────────────────────────────────────────────────────

output "monitoring_dashboard_url" {
  description = "CloudWatch dashboard URL — open this after apply to watch the pipeline run"
  value       = module.monitoring.dashboard_url
}

output "monitoring_sns_topic" {
  description = "SNS ops-alerts topic ARN — add extra subscribers (Slack, PagerDuty) here"
  value       = module.monitoring.sns_topic_arn
}

# ── Analytics Agent outputs ───────────────────────────────────────────────────

output "analytics_agent_ecr_url" {
  description = "ECR repository URL — paste into the CI deploy workflow"
  value       = module.analytics_agent.ecr_repository_url
}

output "analytics_agent_cluster" {
  description = "ECS cluster name — used in aws ecs run-task commands"
  value       = module.analytics_agent.ecs_cluster_name
}

output "analytics_agent_task_definition" {
  description = "Latest ECS task definition ARN"
  value       = module.analytics_agent.task_definition_arn
}

output "analytics_agent_log_group" {
  description = "CloudWatch log group for structured JSON agent logs"
  value       = module.analytics_agent.log_group_name
}

output "analytics_agent_alb_dns" {
  description = "Internal ALB DNS name — POST to http://{dns}/ask from within the VPC"
  value       = module.analytics_agent.alb_dns_name
}

output "analytics_agent_service" {
  description = "ECS service name"
  value       = module.analytics_agent.ecs_service_name
}

# ── Slack MCP Gateway outputs ────────────────────────────────────────────────

output "slack_mcp_gateway_ecr_url" {
  description = "ECR repository URL for the optional Slack MCP gateway"
  value       = try(module.slack_mcp_gateway[0].ecr_repository_url, null)
}

output "slack_mcp_gateway_cluster" {
  description = "ECS cluster name for the optional Slack MCP gateway"
  value       = try(module.slack_mcp_gateway[0].ecs_cluster_name, null)
}

output "slack_mcp_gateway_service" {
  description = "ECS service name for the optional Slack MCP gateway"
  value       = try(module.slack_mcp_gateway[0].ecs_service_name, null)
}

output "slack_mcp_gateway_log_group" {
  description = "CloudWatch log group for the optional Slack MCP gateway"
  value       = try(module.slack_mcp_gateway[0].log_group_name, null)
}

output "slack_mcp_app_token_secret_name" {
  description = "Secrets Manager secret name for SLACK_APP_TOKEN"
  value       = try(module.slack_mcp_gateway[0].slack_app_token_secret_name, null)
}

output "slack_mcp_bot_token_secret_name" {
  description = "Secrets Manager secret name for SLACK_BOT_TOKEN"
  value       = try(module.slack_mcp_gateway[0].slack_bot_token_secret_name, null)
}

# ── Ingestion and bastion outputs — commented out after Phase 1 CDC run ───────
# Uncomment when module "ingestion" and bastion are re-enabled.
#
# output "rds_endpoint" {
#   description = "RDS PostgreSQL hostname for the SSM tunnel command"
#   value       = module.ingestion.rds_endpoint
# }
#
# output "bastion_instance_id" {
#   description = "EC2 bastion instance ID for the SSM tunnel command"
#   value       = aws_instance.bastion.id
# }
#
# output "ssm_tunnel_command" {
#   description = "Run this in a separate terminal to open port 5433 on your Mac to RDS port 5432"
#   value       = "aws ssm start-session --target ${aws_instance.bastion.id} --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters 'host=${module.ingestion.rds_endpoint},portNumber=5432,localPortNumber=5433' --profile dev-admin"
# }
#
# output "simulator_env_block" {
#   description = "Paste these lines into platform-cdc-simulator/.env to point the simulator at RDS"
#   value       = <<-EOT
#     DB_HOST=localhost
#     DB_PORT=5433
#     DB_NAME=ecommerce
#     DB_USER=postgres
#     DB_PASSWORD=<the password you set in TF_VAR_db_password>
#   EOT
# }
