output "ecr_repository_url" {
  description = "ECR repository URL used by CI to push web images"
  value       = aws_ecr_repository.web.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name for the analytics web dashboard"
  value       = aws_ecs_cluster.web.name
}

output "ecs_service_name" {
  description = "ECS service name for the analytics web dashboard"
  value       = aws_ecs_service.web.name
}

output "task_definition_arn" {
  description = "Latest analytics web task definition ARN"
  value       = aws_ecs_task_definition.web.arn
}

output "security_group_id" {
  description = "Analytics web ECS task security group ID"
  value       = aws_security_group.web.id
}

output "url" {
  description = "HTML analytics dashboard URL"
  value       = "http://${var.analytics_agent_url == "" ? "" : replace(var.analytics_agent_url, "http://", "")}:3000"
}
