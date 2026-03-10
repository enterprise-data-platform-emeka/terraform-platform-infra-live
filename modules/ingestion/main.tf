data "aws_caller_identity" "current" {}

locals {
  # Derives "postgres16" from "16.6", etc. Keeps parameter group family in sync with engine version.
  pg_family = "postgres${split(".", var.db_engine_version)[0]}"
}

# Security group for RDS — only allows inbound from DMS and the bastion (added externally via rule).
resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-${var.environment}-rds-sg"
  description = "RDS PostgreSQL source database"
  vpc_id      = var.vpc_id
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

# Security group for DMS replication instance.
resource "aws_security_group" "dms" {
  name        = "${var.name_prefix}-${var.environment}-dms-sg"
  description = "DMS replication instance"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "dms_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.dms.id
}

# RDS parameter group with logical replication enabled for DMS CDC.
# RDS requires a reboot after first apply to activate logical replication.
resource "aws_db_parameter_group" "postgres" {
  name        = "${var.name_prefix}-${var.environment}-${local.pg_family}"
  family      = local.pg_family
  description = "EDP source PostgreSQL - logical replication enabled for DMS CDC"

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

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-${var.environment}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
}

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

  storage_encrypted       = true
  kms_key_id              = var.kms_key_arn
  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = !var.deletion_protection
  multi_az                = var.multi_az
}

resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id          = "${var.name_prefix}-${var.environment}-dms-subnet-group"
  replication_subnet_group_description = "DMS replication subnet group for ${var.environment}"
  subnet_ids                           = var.private_subnet_ids
}

resource "aws_dms_replication_instance" "this" {
  replication_instance_id     = "${var.name_prefix}-${var.environment}-dms-ri"
  replication_instance_class  = var.dms_instance_class
  allocated_storage           = var.dms_allocated_storage
  publicly_accessible         = false
  multi_az                    = var.multi_az
  auto_minor_version_upgrade  = true
  replication_subnet_group_id = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids      = [aws_security_group.dms.id]
}

resource "aws_dms_endpoint" "source" {
  endpoint_id   = "${var.name_prefix}-${var.environment}-source-endpoint"
  endpoint_type = "source"
  engine_name   = "postgres"

  server_name   = aws_db_instance.source.address
  port          = 5432
  database_name = var.db_name
  username      = var.db_username
  password      = var.db_password
  ssl_mode      = "require"
}

# DMS S3 endpoint — writes Parquet files to Bronze with date partitioning.
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
}

# RDS password stored in SSM so Airflow and the ops agent can fetch it without
# a password ever living in a file.
resource "aws_ssm_parameter" "db_password" {
  name        = "/edp/${var.environment}/rds/db_password"
  description = "RDS PostgreSQL master password for ${var.environment}"
  type        = "SecureString"
  value       = var.db_password
  key_id      = var.kms_key_arn
}

resource "aws_dms_replication_task" "cdc" {
  replication_task_id      = "${var.name_prefix}-${var.environment}-cdc-task"
  source_endpoint_arn      = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn      = aws_dms_s3_endpoint.target_s3.endpoint_arn
  replication_instance_arn = aws_dms_replication_instance.this.replication_instance_arn
  migration_type           = "full-load-and-cdc"

  table_mappings = jsonencode({
    rules = [{
      "rule-type"      = "selection"
      "rule-id"        = "1"
      "rule-name"      = "include-all"
      "object-locator" = { "schema-name" = "%", "table-name" = "%" }
      "rule-action"    = "include"
    }]
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
      TargetTablePrepMode             = "DROP_AND_CREATE"
      CreatePkAfterFullLoad           = false
      StopTaskCachedChangesApplied    = false
      StopTaskCachedChangesNotApplied = false
      MaxFullLoadSubTasks             = 8
      TransactionConsistencyTimeout   = 600
      CommitRate                      = 50000
    }
    Logging = { EnableLogging = true }
  })
}
