output "ecr_repository_url" {
  description = "ECR repository URL used by CI to tag and push gateway images"
  value       = aws_ecr_repository.gateway.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name for the Slack MCP gateway"
  value       = aws_ecs_cluster.gateway.name
}

output "ecs_service_name" {
  description = "ECS service name for the Slack MCP gateway"
  value       = aws_ecs_service.gateway.name
}

output "task_definition_arn" {
  description = "Latest ECS task definition ARN"
  value       = aws_ecs_task_definition.gateway.arn
}

output "task_role_arn" {
  description = "IAM task role ARN used by the gateway process"
  value       = aws_iam_role.task.arn
}

output "security_group_id" {
  description = "ECS task security group ID"
  value       = aws_security_group.gateway.id
}

output "log_group_name" {
  description = "CloudWatch log group for Slack MCP gateway logs"
  value       = aws_cloudwatch_log_group.gateway.name
}

output "slack_app_token_secret_name" {
  description = "Secrets Manager secret name for SLACK_APP_TOKEN"
  value       = aws_secretsmanager_secret.slack_app_token.name
}

output "slack_bot_token_secret_name" {
  description = "Secrets Manager secret name for SLACK_BOT_TOKEN"
  value       = aws_secretsmanager_secret.slack_bot_token.name
}

