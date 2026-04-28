output "sns_topic_arn" {
  description = "ARN of the ops-alerts SNS topic. Add extra subscribers (Slack Lambda, PagerDuty) here."
  value       = aws_sns_topic.ops_alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.platform.dashboard_name
}

output "dashboard_url" {
  description = "Direct link to the CloudWatch dashboard in the AWS console"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.platform.dashboard_name}"
}

output "sfn_alarm_arn" {
  description = "ARN of the Step Functions pipeline failure alarm"
  value       = aws_cloudwatch_metric_alarm.sfn_failure.arn
}
