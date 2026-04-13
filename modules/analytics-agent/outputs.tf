output "ecr_repository_url" {
  description = "ECR repository URL — used by CI to tag and push images"
  value       = aws_ecr_repository.agent.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name — used to run one-off tasks from the CLI"
  value       = aws_ecs_cluster.agent.name
}

output "task_definition_arn" {
  description = "Latest registered task definition ARN"
  value       = aws_ecs_task_definition.agent.arn
}

output "task_role_arn" {
  description = "IAM task role ARN — the runtime identity of the agent process"
  value       = aws_iam_role.task.arn
}

output "security_group_id" {
  description = "ECS task security group ID"
  value       = aws_security_group.agent.id
}

output "log_group_name" {
  description = "CloudWatch log group — query here for structured JSON agent logs"
  value       = aws_cloudwatch_log_group.agent.name
}

output "alb_dns_name" {
  description = "Internal ALB DNS name. POST to http://{alb_dns_name}/ask from within the VPC."
  value       = aws_lb.agent.dns_name
}

output "streamlit_url" {
  description = "Streamlit UI URL. Open in a browser from within the VPC: http://{alb_dns_name}:8501"
  value       = "http://${aws_lb.agent.dns_name}:8501"
}

output "ecs_service_name" {
  description = "ECS service name — used by CI to trigger rolling deploys."
  value       = aws_ecs_service.agent.name
}
