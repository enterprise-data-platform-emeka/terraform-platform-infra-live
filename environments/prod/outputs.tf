# ── Orchestration outputs ─────────────────────────────────────────────────────

output "mwaa_webserver_url" {
  description = "Airflow web UI URL — open after apply to trigger the edp_pipeline DAG"
  value       = module.orchestration.mwaa_webserver_url
}

output "mwaa_dags_bucket" {
  description = "S3 bucket where Airflow DAG files are uploaded"
  value       = module.orchestration.dags_bucket_name
}

output "run_dbt_job_name" {
  description = "Glue Python Shell job name for the dbt Gold run — referenced by the MWAA DAG"
  value       = module.orchestration.run_dbt_job_name
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
  description = "DMS replication task ARN"
  value       = module.ingestion.dms_replication_task_arn
}

output "rds_identifier" {
  description = "RDS source DB identifier"
  value       = module.ingestion.rds_identifier
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

# ── Analytics Agent outputs — uncomment when module "analytics_agent" is enabled ──
#
# output "monitoring_dashboard_url" {
#   description = "CloudWatch dashboard URL — open this after apply to watch the pipeline run"
#   value       = module.monitoring.dashboard_url
# }
#
# output "monitoring_sns_topic" {
#   description = "SNS ops-alerts topic ARN — add extra subscribers here"
#   value       = module.monitoring.sns_topic_arn
# }
#
# output "analytics_agent_ecr_url" {
#   description = "ECR repository URL — paste into the CI deploy workflow"
#   value       = module.analytics_agent.ecr_repository_url
# }
#
# output "analytics_agent_alb_dns" {
#   description = "ALB DNS name — POST to http://{dns}/ask from within the VPC"
#   value       = module.analytics_agent.alb_dns_name
# }
#
# output "analytics_agent_log_group" {
#   description = "CloudWatch log group for structured JSON agent logs"
#   value       = module.analytics_agent.log_group_name
# }
