data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "EnterpriseDataPlatform"
    AccountID   = data.aws_caller_identity.current.account_id
  }

  # Derives "postgres16" from "16.6", "postgres15" from "15.4", etc.
  # Keeps the parameter group family in sync with the engine version automatically.
  pg_major_version = split(".", var.db_engine_version)[0]
  pg_family        = "postgres${local.pg_major_version}"
}

######################################################
# Security Group – RDS Source Database
######################################################

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-${var.environment}-rds-sg"
  description = "RDS PostgreSQL source database"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_security_group_rule" "rds_ingress_dms" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.dms.id
  security_group_id        = aws_security_group.rds.id
  description              = "Allow DMS replication instance to reach RDS"
}

resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
}

######################################################
# Security Group – DMS Replication Instance
######################################################

resource "aws_security_group" "dms" {
  name        = "${var.name_prefix}-${var.environment}-dms-sg"
  description = "DMS replication instance"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_security_group_rule" "dms_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.dms.id
}

######################################################
# RDS Parameter Group – enable logical replication for CDC
######################################################

resource "aws_db_parameter_group" "postgres" {
  name        = "${var.name_prefix}-${var.environment}-${local.pg_family}"
  family      = local.pg_family
  description = "EDP source PostgreSQL - logical replication enabled for DMS CDC"
  tags        = local.common_tags

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "wal_sender_timeout"
    value        = "0"
    apply_method = "pending-reboot"
  }
}

######################################################
# RDS Subnet Group
######################################################

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-${var.environment}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

######################################################
# RDS PostgreSQL Instance – CDC Source
######################################################

resource "aws_db_instance" "source" {
  identifier        = "${var.name_prefix}-${var.environment}-source-db"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.postgres.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = !var.deletion_protection

  multi_az = var.multi_az

  tags = local.common_tags
}

######################################################
# DMS Replication Subnet Group
######################################################

resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id          = "${var.name_prefix}-${var.environment}-dms-subnet-group"
  replication_subnet_group_description = "DMS replication subnet group for ${var.environment}"
  subnet_ids                           = var.private_subnet_ids
  tags                                 = local.common_tags
}

######################################################
# DMS Replication Instance
######################################################

resource "aws_dms_replication_instance" "this" {
  replication_instance_id    = "${var.name_prefix}-${var.environment}-dms-ri"
  replication_instance_class = var.dms_instance_class
  allocated_storage          = var.dms_allocated_storage
  publicly_accessible         = false
  multi_az                    = var.multi_az
  auto_minor_version_upgrade  = true

  replication_subnet_group_id = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids      = [aws_security_group.dms.id]

  tags = local.common_tags

  depends_on = [
    # DMS requires these account-level IAM roles to exist before creating
    # replication instances. They are created in the iam-metadata module.
    # If this fails, ensure the iam-metadata module was applied first.
  ]
}

######################################################
# DMS Source Endpoint – RDS PostgreSQL
######################################################

resource "aws_dms_endpoint" "source" {
  endpoint_id   = "${var.name_prefix}-${var.environment}-source-endpoint"
  endpoint_type = "source"
  engine_name   = "postgres"

  server_name = aws_db_instance.source.address
  port        = 5432
  database_name = var.db_name
  username    = var.db_username
  password    = var.db_password

  ssl_mode = "none"
  tags     = local.common_tags
}

######################################################
# DMS Target Endpoint – S3 Bronze (Parquet + CDC partitioning)
#
# aws_dms_s3_endpoint is the dedicated resource for S3 targets/sources
# in AWS provider 5.x. The s3_settings nested block was removed from
# aws_dms_endpoint in that version.
######################################################

resource "aws_dms_s3_endpoint" "target_s3" {
  endpoint_id             = "${var.name_prefix}-${var.environment}-bronze-s3-endpoint"
  endpoint_type           = "target"
  service_access_role_arn = var.dms_s3_role_arn

  bucket_name                      = var.bronze_bucket_name
  bucket_folder                    = "raw"
  compression_type                 = "GZIP"
  data_format                      = "parquet"
  parquet_version                  = "parquet-2-0"
  parquet_timestamp_in_millisecond = true
  date_partition_enabled           = true
  date_partition_sequence          = "YYYYMMDD"
  timestamp_column_name            = "_dms_timestamp"
  include_op_for_full_load         = true
  cdc_inserts_and_updates          = true

  tags = local.common_tags
}

######################################################
# SSM Parameter – RDS password
#
# Stored here so every downstream tool (simulator, Airflow, ops agent)
# can fetch it by name without any password ever living in a file.
######################################################

resource "aws_ssm_parameter" "db_password" {
  name        = "/edp/${var.environment}/rds/db_password"
  description = "RDS PostgreSQL master password — ${var.environment}"
  type        = "SecureString"
  value       = var.db_password
  key_id      = var.kms_key_arn

  tags = local.common_tags
}

######################################################
# DMS Replication Task – Full Load + CDC
######################################################

resource "aws_dms_replication_task" "cdc" {
  replication_task_id      = "${var.name_prefix}-${var.environment}-cdc-task"
  source_endpoint_arn      = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn      = aws_dms_s3_endpoint.target_s3.endpoint_arn
  replication_instance_arn = aws_dms_replication_instance.this.replication_instance_arn
  migration_type           = "full-load-and-cdc"

  # Replicate all schemas and tables; narrow this in production
  table_mappings = jsonencode({
    rules = [
      {
        "rule-type"    = "selection"
        "rule-id"      = "1"
        "rule-name"    = "include-all"
        "object-locator" = {
          "schema-name" = "%"
          "table-name"  = "%"
        }
        "rule-action" = "include"
      }
    ]
  })

  replication_task_settings = jsonencode({
    TargetMetadata = {
      SupportLobs        = true
      FullLobMode        = false
      LobChunkSize       = 64
      LimitedSizeLobMode = true
      LobMaxSize         = 32
    }
    FullLoadSettings = {
      TargetTablePrepMode              = "DROP_AND_CREATE"
      CreatePkAfterFullLoad            = false
      StopTaskCachedChangesApplied     = false
      StopTaskCachedChangesNotApplied  = false
      MaxFullLoadSubTasks              = 8
      TransactionConsistencyTimeout    = 600
      CommitRate                       = 50000
    }
    Logging = {
      EnableLogging = true
    }
  })

  tags = local.common_tags
}
