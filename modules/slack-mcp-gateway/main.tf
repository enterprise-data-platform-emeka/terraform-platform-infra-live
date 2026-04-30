data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region = data.aws_region.current.name
  prefix = "${var.name_prefix}-${var.environment}"

  slack_app_token_secret_name = "/${var.name_prefix}/${var.environment}/slack_mcp/slack_app_token"
  slack_bot_token_secret_name = "/${var.name_prefix}/${var.environment}/slack_mcp/slack_bot_token"
}

# ── ECR repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "gateway" {
  name                 = "${local.prefix}-slack-mcp-gateway"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "gateway" {
  repository = aws_ecr_repository.gateway.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Secrets Manager placeholders ─────────────────────────────────────────────
# Terraform creates the secret containers, but not secret versions. Put values
# in manually or from CI so token values never enter Terraform state.

resource "aws_secretsmanager_secret" "slack_app_token" {
  name                    = local.slack_app_token_secret_name
  description             = "Slack Socket Mode app token for the EDP Slack MCP gateway"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "slack_bot_token" {
  name                    = local.slack_bot_token_secret_name
  description             = "Slack bot token for the EDP Slack MCP gateway"
  recovery_window_in_days = 0
}

# ── ECS cluster and logs ─────────────────────────────────────────────────────

resource "aws_ecs_cluster" "gateway" {
  name = "${local.prefix}-slack-mcp-gateway"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "gateway" {
  cluster_name = aws_ecs_cluster.gateway.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/ecs/${local.prefix}-slack-mcp-gateway"
  retention_in_days = 30
}

# ── IAM ──────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.prefix}-slack-mcp-gateway-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid    = "ReadSlackTokenSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.slack_app_token.arn,
      aws_secretsmanager_secret.slack_bot_token.arn,
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "${local.prefix}-slack-mcp-gateway-exec-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${local.prefix}-slack-mcp-gateway-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid    = "ECSExec"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.prefix}-slack-mcp-gateway-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ── Networking ───────────────────────────────────────────────────────────────
# The gateway is outbound-only. Socket Mode connects to Slack over HTTPS and
# the gateway calls the analytics agent API over HTTP in dev.

resource "aws_security_group" "gateway" {
  name        = "${local.prefix}-slack-mcp-gateway-sg"
  description = "Slack MCP gateway ECS tasks"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to Slack and AWS APIs via NAT Gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP to analytics agent ALB in dev"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── ECS task and service ─────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "gateway" {
  family                   = "${local.prefix}-slack-mcp-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "gateway"
      image     = "${aws_ecr_repository.gateway.repository_url}:latest"
      essential = true

      linuxParameters = { initProcessEnabled = true }

      environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AWS_REGION", value = local.region },
        { name = "ANALYTICS_AGENT_URL", value = var.analytics_agent_url },
        { name = "SLACK_ALLOWED_CHANNELS", value = var.allowed_channels },
        { name = "LOG_LEVEL", value = "INFO" },
      ]

      secrets = [
        { name = "SLACK_APP_TOKEN", valueFrom = aws_secretsmanager_secret.slack_app_token.arn },
        { name = "SLACK_BOT_TOKEN", valueFrom = aws_secretsmanager_secret.slack_bot_token.arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "gateway"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "gateway" {
  name                   = "${local.prefix}-slack-mcp-gateway"
  cluster                = aws_ecs_cluster.gateway.id
  task_definition        = aws_ecs_task_definition.gateway.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.gateway.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

