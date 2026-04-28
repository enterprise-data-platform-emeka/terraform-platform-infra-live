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
