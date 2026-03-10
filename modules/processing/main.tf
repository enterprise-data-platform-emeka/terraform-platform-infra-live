data "aws_subnet" "private_a" {
  id = var.private_subnet_ids[0]
}

# Glue workers communicate with each other on all TCP ports. The self-referencing
# ingress rule allows any member of this group to reach any other member.
resource "aws_security_group" "glue" {
  name        = "${var.name_prefix}-${var.environment}-glue-sg"
  description = "Security group for Glue PySpark jobs"
  vpc_id      = var.vpc_id

  ingress {
    description = "Glue worker-to-worker communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${var.environment}-glue-sg" }
}

# Glue security configuration encrypts job bookmarks, CloudWatch logs, and S3 output.
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

# Glue VPC connection tells Glue which subnet and security group to run jobs in.
# Without this, Glue runs in AWS-managed shared infra and cannot reach private RDS.
resource "aws_glue_connection" "vpc" {
  name            = "${var.name_prefix}-${var.environment}-glue-vpc-connection"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.private_a.availability_zone
    security_group_id_list = [aws_security_group.glue.id]
    subnet_id              = var.private_subnet_ids[0]
  }
}

# Athena workgroup enforces result location and KMS encryption on every query.
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
}
