data "aws_caller_identity" "current" {}

# ── Security group for Redshift Serverless ────────────────────────────────────

resource "aws_security_group" "redshift" {
  name        = "${var.name_prefix}-${var.environment}-redshift-sg"
  description = "Security group for Redshift Serverless workgroup"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redshift port - allow from within the VPC"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.name_prefix}-${var.environment}-redshift-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

# ── Redshift Serverless namespace ─────────────────────────────────────────────
#
# A namespace is the administrative container for a Redshift Serverless
# deployment. It holds the database storage, admin credentials, and the
# IAM role that Redshift uses to read from S3 and the Glue catalog.
#
# Namespaces are account-level resources. They are not deployed inside
# a VPC. The workgroup (below) is what lives in the VPC.

resource "aws_redshiftserverless_namespace" "this" {
  namespace_name      = "${var.name_prefix}-${var.environment}-namespace"
  admin_username      = var.redshift_admin_username
  admin_user_password = var.redshift_admin_password
  db_name             = var.redshift_db_name

  iam_roles   = [var.redshift_role_arn]
  kms_key_id  = var.kms_key_arn

  log_exports = ["userlog", "connectionlog", "useractivitylog"]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }
}

# ── Redshift Serverless workgroup ─────────────────────────────────────────────
#
# A workgroup is the compute layer. It lives inside the VPC, uses the
# private subnets, and is where SQL connections are made. The workgroup
# references the namespace for storage and credentials.
#
# base_capacity is measured in RPUs (Redshift Processing Units).
# 8 RPUs is the minimum for Redshift Serverless and is enough for
# development and moderate query workloads.

resource "aws_redshiftserverless_workgroup" "this" {
  namespace_name = aws_redshiftserverless_namespace.this.namespace_name
  workgroup_name = "${var.name_prefix}-${var.environment}-workgroup"

  base_capacity       = var.base_capacity_rpus
  publicly_accessible = false

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.redshift.id]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
  }

  depends_on = [aws_redshiftserverless_namespace.this]
}
