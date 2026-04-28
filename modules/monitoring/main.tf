data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix            = "${var.name_prefix}-${var.environment}"
  state_machine_arn = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.state_machine_name}"
}

# ── SNS topic and email subscription ─────────────────────────────────────────
# All five alarms send to this one topic. AWS sends a confirmation email to the
# address when the subscription is first created — click the link to activate it.
# Until confirmed the subscription stays in PendingConfirmation and no alerts are
# delivered.

resource "aws_sns_topic" "ops_alerts" {
  name = "${local.prefix}-ops-alerts"

  tags = {
    Project     = "EnterpriseDataPlatform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Alarm 1: Step Functions pipeline execution failed ─────────────────────────
# Fires when the edp-dev-pipeline state machine ends in a FAILED state.
# This covers every failure downstream of Step Functions: a Silver Glue job
# crashing, the crawler failing, or the dbt Gold job erroring.

resource "aws_cloudwatch_metric_alarm" "sfn_failure" {
  alarm_name          = "${local.prefix}-pipeline-failed"
  alarm_description   = "The EDP data pipeline Step Functions execution failed. Check the Step Functions console for which state failed."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = local.state_machine_arn
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]

  tags = {
    Project     = "EnterpriseDataPlatform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Alarm 2: Analytics Agent has no running ECS tasks ────────────────────────
# Container Insights emits RunningTaskCount per service. A count of 0 means
# every task has crashed or been stopped. evaluation_periods = 2 avoids
# false positives during normal rolling deploys (one task stops, another starts).

resource "aws_cloudwatch_metric_alarm" "ecs_no_tasks" {
  alarm_name          = "${local.prefix}-agent-no-running-tasks"
  alarm_description   = "The Analytics Agent has no running ECS tasks. The service may have crashed. Check ECS stopped task reasons."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]

  tags = {
    Project     = "EnterpriseDataPlatform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Alarm 3: Analytics Agent ECS CPU utilisation above 80% ───────────────────
# Sustained high CPU usually means the container is stuck processing a request
# or looping. Two consecutive periods before firing to avoid single-spike noise.

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${local.prefix}-agent-cpu-high"
  alarm_description   = "Analytics Agent ECS CPU utilisation above 80% for 2 consecutive minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]

  tags = {
    Project     = "EnterpriseDataPlatform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Alarm 4: ALB returning 5xx errors to users ───────────────────────────────
# HTTPCode_ELB_5XX_Count covers both 502 (bad gateway, ECS task unreachable)
# and 504 (gateway timeout, ECS task took too long). A threshold of 5 over
# 60 seconds gives some tolerance for transient blips while still catching
# sustained failure modes quickly.

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.prefix}-agent-alb-5xx"
  alarm_description   = "Analytics Agent ALB is returning 5xx errors. Check ECS task health and CloudWatch logs."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]

  tags = {
    Project     = "EnterpriseDataPlatform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Alarm 5: ALB P99 response time above 30 seconds ─────────────────────────
# Each Analytics Agent request makes three Claude API calls sequentially
# (SQL + insight + verdict). The Claude API circuit breaker is set at 30s
# per call, so 90s total is the hard ceiling. A P99 > 30s means more than
# 1% of requests are already past one full Claude call cycle — something
# is slow or stalling.

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${local.prefix}-agent-alb-latency-p99"
  alarm_description   = "Analytics Agent P99 response time exceeded 30 seconds. Check Claude API latency and Athena query times."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 30
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]

  tags = {
    Project     = "EnterpriseDataPlatform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
# Four metric panels and one alarm status bar. All metric panels use a 300s
# (5-minute) period to smooth out per-minute noise on the overview.
# The alarm status bar at the bottom shows the current ALARM/OK state of all
# five alarms at a glance.

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${local.prefix}-platform"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "Pipeline Executions (Step Functions)"
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", local.state_machine_arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", local.state_machine_arn],
            ["AWS/States", "ExecutionsThrottled", "StateMachineArn", local.state_machine_arn],
          ]
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          region = data.aws_region.current.name
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "Analytics Agent — ECS CPU and Memory"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ServiceName", var.ecs_service_name, "ClusterName", var.ecs_cluster_name],
            ["AWS/ECS", "MemoryUtilization", "ServiceName", var.ecs_service_name, "ClusterName", var.ecs_cluster_name],
          ]
          period = 300
          stat   = "Average"
          view   = "timeSeries"
          region = data.aws_region.current.name
          yAxis = {
            left = { min = 0, max = 100 }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Analytics Agent — ALB Request Count and 5xx Errors"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix],
          ]
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          region = data.aws_region.current.name
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Analytics Agent — ALB Response Time (P99)"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix],
          ]
          period = 300
          stat   = "p99"
          view   = "timeSeries"
          region = data.aws_region.current.name
          yAxis = {
            left = { min = 0 }
          }
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 12
        width  = 24
        height = 2
        properties = {
          title = "Alarm Status"
          alarms = [
            aws_cloudwatch_metric_alarm.sfn_failure.arn,
            aws_cloudwatch_metric_alarm.ecs_no_tasks.arn,
            aws_cloudwatch_metric_alarm.ecs_cpu_high.arn,
            aws_cloudwatch_metric_alarm.alb_5xx.arn,
            aws_cloudwatch_metric_alarm.alb_latency.arn,
          ]
        }
      },
    ]
  })
}
