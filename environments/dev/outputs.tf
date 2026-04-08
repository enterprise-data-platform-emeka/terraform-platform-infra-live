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
