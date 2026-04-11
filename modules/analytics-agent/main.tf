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

  # Gold S3 — read for Athena queries, write for chart PNGs uploaded by charts.py.
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

  # Gold S3 charts/ prefix — write only. charts.py uploads one PNG per question.
  # Presigned URL expiry means the object is effectively temporary.
  statement {
    sid     = "GoldChartsWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "arn:aws:s3:::${var.gold_bucket_name}/charts/*",
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
      "s3:GetBucketLocation",
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
    sid    = "BronzeMetadataRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.bronze_bucket_name}",
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

  # Glue Catalog — read only on Gold and Silver databases.
  # Gold tables are views built on Silver; Athena must resolve both databases
  # when executing queries against Gold views.
  statement {
    sid    = "GlueCatalogReadOnly"
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
      "arn:aws:glue:${local.region}:${local.account_id}:database/${var.glue_silver_database}",
      "arn:aws:glue:${local.region}:${local.account_id}:table/${var.glue_silver_database}/*",
      # dbt-athena embeds the dbt source name (silver) as the schema in Gold views,
      # not the full Glue database name. Athena resolves views using this literal name.
      "arn:aws:glue:${local.region}:${local.account_id}:database/silver",
      "arn:aws:glue:${local.region}:${local.account_id}:table/silver/*",
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

  # ECS Exec — allows aws ecs execute-command to open an interactive shell
  # into a running Fargate task for debugging and manual testing.
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
  name   = "${local.prefix}-analytics-agent-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ── Security groups ───────────────────────────────────────────────────────────
# Two security groups are needed: one for the ALB (port 80 inbound from anywhere)
# and one for the ECS tasks (port 8080 inbound from ALB, HTTPS egress to AWS APIs).
#
# The ingress rule on the ECS SG is defined as a separate aws_security_group_rule
# resource (not inline) to break the circular dependency between the two SGs.

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-analytics-agent-alb-sg"
  description = "Analytics agent ALB - inbound port 80"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere (dev environment)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (ALB routes to ECS tasks)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "agent" {
  name        = "${local.prefix}-analytics-agent-sg"
  description = "Analytics agent ECS tasks"
  vpc_id      = var.vpc_id

  # No inline ingress — defined separately below to avoid circular SG reference.

  egress {
    description = "HTTPS to AWS APIs and Anthropic API via NAT Gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Separate rule so the ALB SG and ECS SG can reference each other without
# creating a Terraform circular dependency at the resource level.
resource "aws_security_group_rule" "agent_ingress_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.agent.id
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "Port 8080 from ALB to FastAPI"
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

      # Required for ECS Exec (interactive shell via aws ecs execute-command).
      linuxParameters = { initProcessEnabled = true }

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

      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
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

  # No ignore_changes here: Terraform must register a new task definition
  # revision whenever container_definitions changes (e.g. adding portMappings).
  # The ECS service has ignore_changes = [task_definition] so CI-pushed
  # revisions are never rolled back by terraform apply.
}

# ── ALB ───────────────────────────────────────────────────────────────────────
# Internal ALB — accessible from within the VPC only. For a test session, reach
# it via the bastion host or ECS Exec. The VPC design has only one public subnet
# so the ALB is placed in the two private subnets (each in a different AZ), which
# is all an ALB needs to operate.
#
# For the test-and-destroy workflow, HTTP (port 80) is sufficient. HTTPS requires
# an ACM certificate which needs a domain name — out of scope for dev testing.

resource "aws_lb" "agent" {
  name               = "${local.prefix}-agent-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  # Access logs are disabled for dev. Enable for staging/prod when an access
  # log S3 bucket is available.
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "agent" {
  name        = "${local.prefix}-agent-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Required for Fargate awsvpc networking mode.

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener" "agent_http" {
  load_balancer_arn = aws_lb.agent.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }
}

# ── ECS service ───────────────────────────────────────────────────────────────
# Keeps one Fargate task running behind the ALB. desired_count defaults to 1 and
# is ignored by Terraform after initial creation so `aws ecs update-service
# --desired-count 0` can pause the service between test sessions without
# triggering a Terraform diff on next plan.

resource "aws_ecs_service" "agent" {
  name                   = "${local.prefix}-analytics-agent"
  cluster                = aws_ecs_cluster.agent.id
  task_definition        = aws_ecs_task_definition.agent.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.agent.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.agent.arn
    container_name   = "agent"
    container_port   = 8080
  }

  # CI registers new task definition revisions and calls update-service directly.
  # Terraform owns sizing, networking, and IAM — not the specific image tag or
  # the current scale of the service.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.agent_http]
}
