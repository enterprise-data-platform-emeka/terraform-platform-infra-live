data "aws_caller_identity" "current" {}

resource "aws_security_group" "redshift" {
  name        = "${var.name_prefix}-${var.environment}-redshift-sg"
  description = "Security group for Redshift Serverless workgroup"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redshift port from within the VPC"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${var.environment}-redshift-sg" }
}

# Namespace is the storage/admin container. Workgroup is the compute layer in the VPC.
resource "aws_redshiftserverless_namespace" "this" {
  namespace_name      = "${var.name_prefix}-${var.environment}-namespace"
  admin_username      = var.redshift_admin_username
  admin_user_password = var.redshift_admin_password
  db_name             = var.redshift_db_name
  iam_roles           = [var.redshift_role_arn]
  kms_key_id          = var.kms_key_arn
  log_exports         = ["userlog", "connectionlog", "useractivitylog"]
}

resource "aws_redshiftserverless_workgroup" "this" {
  namespace_name      = aws_redshiftserverless_namespace.this.namespace_name
  workgroup_name      = "${var.name_prefix}-${var.environment}-workgroup"
  base_capacity       = var.base_capacity_rpus
  publicly_accessible = false
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.redshift.id]

  depends_on = [aws_redshiftserverless_namespace.this]
}

# Redshift admin password stored in SSM for dbt, Airflow, and the ops agent.
resource "aws_ssm_parameter" "redshift_admin_password" {
  name        = "/edp/${var.environment}/redshift/admin_password"
  description = "Redshift Serverless admin password for ${var.environment}"
  type        = "SecureString"
  value       = var.redshift_admin_password
  key_id      = var.kms_key_arn
}
