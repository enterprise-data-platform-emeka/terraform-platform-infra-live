# -----------------------------------------------------------------------------
# CDC simulator runtime outputs
# -----------------------------------------------------------------------------
# Exposes simulator repository, cluster, task definition, and security group IDs.

output "ecr_repository_url" {
  description = "ECR repository URL for CDC simulator images."
  value       = aws_ecr_repository.simulator.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name for one-off simulator tasks."
  value       = aws_ecs_cluster.simulator.name
}

output "task_definition_arn" {
  description = "CDC simulator ECS task definition ARN."
  value       = aws_ecs_task_definition.simulator.arn
}

output "container_name" {
  description = "CDC simulator container name inside the task definition."
  value       = "simulator"
}

output "security_group_id" {
  description = "Security group ID for CDC simulator tasks."
  value       = aws_security_group.simulator.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for CDC simulator tasks."
  value       = var.private_subnet_ids
}

output "log_group_name" {
  description = "CloudWatch log group for CDC simulator task logs."
  value       = aws_cloudwatch_log_group.simulator.name
}
