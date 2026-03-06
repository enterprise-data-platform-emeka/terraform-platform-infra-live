data "aws_subnet" "private_a" {
  id = var.private_subnet_ids[0]
}

# ── Security group for Glue ───────────────────────────────────────────────────
#
# Glue runs distributed PySpark workers inside the VPC. The workers need to
# communicate with each other, which requires a self-referencing ingress rule
# (traffic from any member of this security group is allowed in).

resource "aws_security_group" "glue" {
  name        = "${var.name_prefix}-${var.environment}-glue-sg"
  description = "Security group for Glue PySpark jobs"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow Glue workers to communicate with each other"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound (S3 via VPC endpoint, RDS in VPC)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.name_prefix}-${var.environment}-glue-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

# Allow Glue to connect to RDS on port 5432 (added to RDS security group
# from the ingestion module — referenced here by passing this sg id as output)


# ── Glue security configuration ──────────────────────────────────────────────
#
# A Glue security configuration tells Glue to encrypt:
#   - Job bookmarks (the progress checkpoints Glue saves between runs)
#   - CloudWatch logs written by Glue jobs
#   - Data Glue writes to S3 (Silver and Gold buckets)
#
# All three use the platform KMS key so everything is encrypted with
# the same key and access is managed in one place.

resource "aws_glue_security_configuration" "this" {
  name = "${var.name_prefix}-${var.environment}-glue-sec-config"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
  }
}

# ── Glue VPC connection ───────────────────────────────────────────────────────
#
# A Glue network connection tells Glue which VPC, subnet, and security group
# to run jobs in. Without this, Glue runs in AWS-managed shared infrastructure
# and cannot reach resources inside the private subnets (like RDS).
#
# Glue jobs reference this connection by name when they are defined.

resource "aws_glue_connection" "vpc" {
  name            = "${var.name_prefix}-${var.environment}-glue-vpc-connection"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.private_a.availability_zone
    security_group_id_list = [aws_security_group.glue.id]
    subnet_id              = var.private_subnet_ids[0]
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

# ── Athena workgroup ──────────────────────────────────────────────────────────
#
# An Athena workgroup groups queries together for cost tracking and access
# control. I enforce two things:
#   1. All query results must go to the athena-results S3 bucket
#   2. All query results must be encrypted with the platform KMS key
#
# enforce_workgroup_configuration = true means individual query callers
# cannot override these settings. Every query follows the workgroup rules.

resource "aws_athena_workgroup" "this" {
  name  = "${var.name_prefix}-${var.environment}-workgroup"
  state = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${var.athena_results_bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}
