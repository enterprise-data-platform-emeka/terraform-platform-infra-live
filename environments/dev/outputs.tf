# ── Monitoring outputs ────────────────────────────────────────────────────────

output "monitoring_dashboard_url" {
  description = "CloudWatch dashboard URL — open this after apply to watch the pipeline run"
  value       = try(module.monitoring[0].dashboard_url, null)
}

output "monitoring_sns_topic" {
  description = "SNS ops-alerts topic ARN — add extra subscribers (Slack, PagerDuty) here"
  value       = try(module.monitoring[0].sns_topic_arn, null)
}

# ── Orchestration outputs ─────────────────────────────────────────────────────

output "step_functions_state_machine_name" {
  description = "Step Functions state machine name when Step Functions is enabled"
  value       = try(module.step_functions[0].state_machine_name, null)
}

output "mwaa_webserver_url" {
  description = "Airflow web UI URL when MWAA is enabled"
  value       = try(module.orchestration[0].mwaa_webserver_url, null)
}

output "mwaa_dags_bucket" {
  description = "S3 bucket where Airflow DAG files are uploaded when MWAA is enabled"
  value       = try(module.orchestration[0].dags_bucket_name, null)
}

output "run_dbt_job_name" {
  description = "Glue Python Shell job name for the dbt Gold run when MWAA is enabled"
  value       = try(module.orchestration[0].run_dbt_job_name, null)
}

# ── Analytics Agent outputs ───────────────────────────────────────────────────

output "analytics_agent_ecr_url" {
  description = "ECR repository URL — paste into the CI deploy workflow"
  value       = try(module.analytics_agent[0].ecr_repository_url, null)
}

output "analytics_agent_cluster" {
  description = "ECS cluster name — used in aws ecs run-task commands"
  value       = try(module.analytics_agent[0].ecs_cluster_name, null)
}

output "analytics_agent_task_definition" {
  description = "Latest ECS task definition ARN"
  value       = try(module.analytics_agent[0].task_definition_arn, null)
}

output "analytics_agent_log_group" {
  description = "CloudWatch log group for structured JSON agent logs"
  value       = try(module.analytics_agent[0].log_group_name, null)
}

output "analytics_agent_alb_dns" {
  description = "Internal ALB DNS name — POST to http://{dns}/ask from within the VPC"
  value       = try(module.analytics_agent[0].alb_dns_name, null)
}

output "analytics_agent_service" {
  description = "ECS service name"
  value       = try(module.analytics_agent[0].ecs_service_name, null)
}

# ── CDC Simulator outputs ───────────────────────────────────────────────────

output "cdc_simulator_ecr_url" {
  description = "ECR repository URL for the optional CDC simulator task image"
  value       = try(module.source_simulator_runtime[0].ecr_repository_url, null)
}

output "cdc_simulator_cluster" {
  description = "ECS cluster name for optional CDC simulator one-off tasks"
  value       = try(module.source_simulator_runtime[0].ecs_cluster_name, null)
}

output "cdc_simulator_task_definition" {
  description = "ECS task definition ARN for optional CDC simulator one-off tasks"
  value       = try(module.source_simulator_runtime[0].task_definition_arn, null)
}

output "cdc_simulator_container_name" {
  description = "CDC simulator container name"
  value       = try(module.source_simulator_runtime[0].container_name, null)
}

output "cdc_simulator_security_group_id" {
  description = "Security group ID for optional CDC simulator tasks"
  value       = try(module.source_simulator_runtime[0].security_group_id, null)
}

output "cdc_simulator_private_subnet_ids" {
  description = "Private subnet IDs used by optional CDC simulator tasks"
  value       = try(module.source_simulator_runtime[0].private_subnet_ids, [])
}

output "cdc_simulator_log_group" {
  description = "CloudWatch log group for optional CDC simulator task logs"
  value       = try(module.source_simulator_runtime[0].log_group_name, null)
}

output "dms_replication_task_arn" {
  description = "DMS replication task ARN when CDC simulator infrastructure is enabled"
  value       = try(module.ingestion[0].dms_replication_task_arn, null)
}

output "rds_identifier" {
  description = "RDS source DB identifier when CDC simulator infrastructure is enabled"
  value       = try(module.ingestion[0].rds_identifier, null)
}

# ── Serving outputs ───────────────────────────────────────────────────────────

output "redshift_namespace_name" {
  description = "Redshift Serverless namespace name when serving is enabled"
  value       = try(module.serving[0].namespace_name, null)
}

output "redshift_workgroup_name" {
  description = "Redshift Serverless workgroup name when serving is enabled"
  value       = try(module.serving[0].workgroup_name, null)
}

output "redshift_workgroup_endpoint" {
  description = "Redshift Serverless endpoint when serving is enabled"
  value       = try(module.serving[0].workgroup_endpoint, null)
}

output "redshift_security_group_id" {
  description = "Redshift security group ID when serving is enabled"
  value       = try(module.serving[0].redshift_security_group_id, null)
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
