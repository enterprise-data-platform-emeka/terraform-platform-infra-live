# -----------------------------------------------------------------------------
# CDC simulator runtime module
# -----------------------------------------------------------------------------
# Creates the optional ECS runtime for the source simulator. The simulator writes
# synthetic e-commerce changes into the private PostgreSQL source database so
# DMS can replicate them into Bronze.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region                    = data.aws_region.current.name
  prefix                    = "${var.name_prefix}-${var.environment}"
  ssm_db_password_parameter = "arn:aws:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_db_password_path}"
}

# -----------------------------------------------------------------------------
# 1. Container image repository
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "simulator" {
  name                 = "${local.prefix}-cdc-simulator"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "simulator" {
  repository = aws_ecr_repository.simulator.name

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
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# 2. ECS cluster and logs
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "simulator" {
  name = "${local.prefix}-cdc-simulator"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "simulator" {
  name              = "/ecs/${local.prefix}-cdc-simulator"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# 3. IAM roles
# -----------------------------------------------------------------------------

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
  name               = "${local.prefix}-cdc-simulator-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid       = "ReadDatabasePassword"
    effect    = "Allow"
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = [local.ssm_db_password_parameter]
  }

  statement {
    sid       = "DecryptDatabasePassword"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "${local.prefix}-cdc-simulator-exec-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${local.prefix}-cdc-simulator-task-role"
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
  name   = "${local.prefix}-cdc-simulator-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# -----------------------------------------------------------------------------
# 4. Network access to source RDS
# -----------------------------------------------------------------------------

resource "aws_security_group" "simulator" {
  name        = "${local.prefix}-cdc-simulator-sg"
  description = "CDC simulator ECS one-off tasks"
  vpc_id      = var.vpc_id

  egress {
    description = "PostgreSQL to source RDS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS to AWS APIs through NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "rds_ingress_simulator" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.simulator.id
  security_group_id        = var.rds_security_group_id
  description              = "Allow CDC simulator tasks to reach source RDS"
}

# -----------------------------------------------------------------------------
# 5. ECS task definition
# -----------------------------------------------------------------------------

resource "aws_ecs_task_definition" "simulator" {
  family                   = "${local.prefix}-cdc-simulator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "simulator"
      image     = "${aws_ecr_repository.simulator.repository_url}:latest"
      essential = true

      environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "DB_HOST", value = var.rds_endpoint },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USER", value = var.db_username },
        { name = "SEED_RANDOM_SEED", value = "42" },
        { name = "SIM_TICK_INTERVAL_SECONDS", value = "2" },
        { name = "SIM_NEW_ORDERS_PER_TICK", value = "3" },
        { name = "RETRY_MAX_ATTEMPTS", value = "8" },
        { name = "RETRY_WAIT_MIN_SECONDS", value = "2" },
        { name = "RETRY_WAIT_MAX_SECONDS", value = "30" },
      ]

      secrets = [
        { name = "DB_PASSWORD", valueFrom = local.ssm_db_password_parameter },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.simulator.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "simulator"
        }
      }
    }
  ])
}
