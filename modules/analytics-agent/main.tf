data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  prefix     = "${var.name_prefix}-${var.environment}"

  # SSM parameter path follows the platform convention: /edp/{env}/anthropic_api_key.
  # The parameter itself is created manually (never in Terraform — secrets don't go in state).
  ssm_api_key_param = "/edp/${var.environment}/anthropic_api_key"

  # Athena workgroup name follows the processing module's naming convention.
  athena_workgroup = "${var.name_prefix}-${var.environment}-workgroup"
}

# ── ECR repository ────────────────────────────────────────────────────────────
# Stores versioned Docker images built and pushed by CI on every merge to main
# in the platform-analytics-agent repo.

resource "aws_ecr_repository" "agent" {
  name                 = "${local.prefix}-analytics-agent"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name

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

# ── ECS cluster ───────────────────────────────────────────────────────────────
# FARGATE only — no EC2 instances to manage. The agent runs as one-off tasks
# invoked from the CLI or (Phase 11) via FastAPI behind an ALB.

resource "aws_ecs_cluster" "agent" {
  name = "${local.prefix}-analytics-agent"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "agent" {
  cluster_name = aws_ecs_cluster.agent.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── CloudWatch log group ──────────────────────────────────────────────────────
# Receives structured JSON logs from agent/logging.py. 30-day retention matches
# the rest of the platform.

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/ecs/${local.prefix}-analytics-agent"
  retention_in_days = 30
  # kms_key_id is intentionally omitted. CloudWatch Logs requires the KMS key
  # policy to explicitly grant logs.{region}.amazonaws.com permission to use
  # the key. The platform KMS key does not include that grant. Log content
  # here is operational metadata, not sensitive pipeline data, so
  # service-managed encryption is appropriate.
}

# ── IAM — task execution role ─────────────────────────────────────────────────
# Used by the ECS control plane to pull the image from ECR and stream logs to
# CloudWatch. Not available to application code at runtime.

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
  name               = "${local.prefix}-analytics-agent-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── IAM — task role ───────────────────────────────────────────────────────────
# The agent process assumes this role at runtime. Every statement maps to a
# specific agent action. Nothing broader than what the code actually calls.

resource "aws_iam_role" "task" {
  name               = "${local.prefix}-analytics-agent-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

data "aws_iam_policy_document" "task" {

  # Gold S3 — read only. The agent queries Gold Parquet files via Athena.
  statement {
    sid    = "GoldS3ReadOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.gold_bucket_name}",
      "arn:aws:s3:::${var.gold_bucket_name}/*",
    ]
  }

  # Athena results bucket — read/write. Athena writes query output here;
  # the agent reads the CSV back to return results to the caller.
  statement {
    sid    = "AthenaResultsReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.athena_results_bucket}",
      "arn:aws:s3:::${var.athena_results_bucket}/*",
    ]
  }

  # Bronze bucket — two scoped prefixes only.
  # metadata/dbt/*: agent reads dbt catalog.json at startup to enrich schemas.
  # metadata/agent-audit/*: agent writes one JSON audit record per question.
  statement {
    sid     = "BronzeMetadataRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.bronze_bucket_name}/metadata/dbt/*",
    ]
  }

  statement {
    sid     = "BronzeAuditWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "arn:aws:s3:::${var.bronze_bucket_name}/metadata/agent-audit/*",
    ]
  }

  # KMS — decrypt S3 objects (platform bucket encryption) and the SSM parameter
  # (SecureString). Scoped to the platform key only.
  statement {
    sid    = "KMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }

  # Glue Catalog — read only on the Gold database.
  # GetTables is called at startup to load all Gold schemas into the system prompt.
  statement {
    sid    = "GlueCatalogGoldReadOnly"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
    ]
    resources = [
      "arn:aws:glue:${local.region}:${local.account_id}:catalog",
      "arn:aws:glue:${local.region}:${local.account_id}:database/${var.glue_gold_database}",
      "arn:aws:glue:${local.region}:${local.account_id}:table/${var.glue_gold_database}/*",
    ]
  }

  # Athena — start, poll, and fetch results for a single query execution.
  statement {
    sid    = "AthenaQueryExecution"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
    ]
    resources = [
      "arn:aws:athena:${local.region}:${local.account_id}:workgroup/${local.athena_workgroup}",
    ]
  }

  # SSM — read the Anthropic API key at startup. Scoped to exact parameter path.
  statement {
    sid     = "SSMApiKeyRead"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.ssm_api_key_param}",
    ]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.prefix}-analytics-agent-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ── Security group ────────────────────────────────────────────────────────────
# ECS tasks need outbound HTTPS to reach AWS APIs (S3, Glue, Athena, SSM) via
# the NAT Gateway and the Anthropic API. No inbound until Phase 11 adds the ALB.

resource "aws_security_group" "agent" {
  name        = "${local.prefix}-analytics-agent-sg"
  description = "Analytics agent ECS tasks - egress only"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to AWS APIs and Anthropic API"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── ECS task definition ───────────────────────────────────────────────────────
# 512 CPU (0.5 vCPU) / 1024 MB is sufficient for pandas + matplotlib + the
# response payload. Adjust task_cpu / task_memory variables for staging/prod.
#
# lifecycle.ignore_changes on container_definitions: CI registers new task
# definition revisions directly after each image push. Terraform owns the
# role, sizing, and log config — CI owns the image tag.

resource "aws_ecs_task_definition" "agent" {
  family                   = "${local.prefix}-analytics-agent"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "agent"
      image     = "${aws_ecr_repository.agent.repository_url}:latest"
      essential = true

      environment = [
        { name = "ENVIRONMENT",           value = var.environment },
        { name = "AWS_REGION",            value = local.region },
        { name = "BRONZE_BUCKET",         value = var.bronze_bucket_name },
        { name = "GOLD_BUCKET",           value = var.gold_bucket_name },
        { name = "ATHENA_RESULTS_BUCKET", value = var.athena_results_bucket },
        { name = "ATHENA_WORKGROUP",      value = local.athena_workgroup },
        { name = "GLUE_GOLD_DATABASE",    value = var.glue_gold_database },
        { name = "SSM_API_KEY_PARAM",     value = local.ssm_api_key_param },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "agent"
        }
      }
    }
  ])

  lifecycle {
    ignore_changes = [container_definitions]
  }
}
