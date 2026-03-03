# Module: ingestion

**Location:** `terraform-platform-infra-live/modules/ingestion/`

**Part of:** Terraform Platform Infra — Data Platform Layer

**Depends on:** `networking` (vpc, subnets), `iam-metadata` (kms_key_arn, dms_s3_role_arn), `data-lake` (bronze_bucket_name)

---

## What This Module Does

This module builds the **data entry point** for the entire platform. It answers the question: "How does data get from the source application database into the S3 data lake?"

The answer is **CDC — Change Data Capture** — using AWS DMS (Database Migration Service).

Instead of copying the entire database every night (a "full extract"), CDC captures every individual change (insert, update, delete) as it happens and streams it into the Bronze S3 bucket as Parquet files. This is faster, cheaper, and more accurate.

---

## The Ingestion Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          VPC (Private Subnets)                      │
│                                                                     │
│   ┌──────────────────────────┐         ┌──────────────────────────┐ │
│   │   RDS PostgreSQL         │         │   DMS Replication        │ │
│   │   Source Database        │◄────────│   Instance               │ │
│   │                          │  reads  │                          │ │
│   │   - Logical replication  │  WAL    │   - Reads PostgreSQL WAL │ │
│   │     enabled              │         │   - Converts to Parquet  │ │
│   │   - Security group       │         │   - Writes to Bronze S3  │ │
│   │     allows DMS only      │         │                          │ │
│   └──────────────────────────┘         └────────────┬─────────────┘ │
│                                                     │               │
└─────────────────────────────────────────────────────┼───────────────┘
                                                      │ writes Parquet files
                                                      ▼
                                           ┌─────────────────────┐
                                           │  Bronze S3 Bucket   │
                                           │                     │
                                           │  raw/               │
                                           │    orders/          │
                                           │      20240115/      │
                                           │        *.parquet    │
                                           └─────────────────────┘
```

---

## What is CDC (Change Data Capture)?

PostgreSQL maintains an internal journal called the **Write-Ahead Log (WAL)**. Every INSERT, UPDATE, and DELETE written to the database is first recorded in this log before being applied to the actual tables.

AWS DMS reads this WAL log and converts each entry into a structured record. For each change, DMS captures:
- The changed row's data
- The operation type: `I` (Insert), `U` (Update), or `D` (Delete)
- A timestamp

These records are written as Parquet files to the Bronze S3 bucket.

**Example Bronze record for an INSERT:**

```
_dms_timestamp: 2024-01-15T10:00:00Z
Op: I
order_id: 12345
customer_id: 678
amount: 99.99
status: "pending"
```

**Example Bronze record for an UPDATE (status changed to "shipped"):**

```
_dms_timestamp: 2024-01-15T14:30:00Z
Op: U
order_id: 12345
customer_id: 678
amount: 99.99
status: "shipped"
```

The Glue Silver job later reads both records and produces one Silver record showing the current state: `status = "shipped"`.

---

## Resources Created

### 1. Security Group — RDS

```hcl
resource "aws_security_group" "rds" {
  name   = "${var.name_prefix}-${var.environment}-rds-sg"
  vpc_id = var.vpc_id
}

resource "aws_security_group_rule" "rds_ingress_dms" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.dms.id   # Only DMS can connect
  security_group_id        = aws_security_group.rds.id
}
```

**What a security group is:** Think of it as a firewall attached to a service. It has inbound rules (what traffic is allowed in) and outbound rules (what traffic is allowed out).

**Port 5432:** PostgreSQL's default port.

**`source_security_group_id = aws_security_group.dms.id`:** This is a security group reference rule. Instead of allowing a specific IP address (which changes every time DMS restarts), this rule says "allow inbound on port 5432 from any resource that belongs to the DMS security group." This is more robust and secure.

---

### 2. Security Group — DMS

```hcl
resource "aws_security_group" "dms" {
  name   = "${var.name_prefix}-${var.environment}-dms-sg"
  vpc_id = var.vpc_id
}
```

Outbound only: DMS needs to reach RDS (port 5432) and S3 (via the VPC endpoint, no specific port needed).

---

### 3. RDS Parameter Group — Enable Logical Replication

```hcl
resource "aws_db_parameter_group" "postgres" {
  name   = "${var.name_prefix}-${var.environment}-postgres16"
  family = "postgres16"

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
```

**What a parameter group is:** A collection of configuration settings for a database engine. AWS applies these settings when the RDS instance starts.

**`rds.logical_replication = 1`:** This is the most critical setting for CDC. By default, PostgreSQL's WAL records only enough information to recover the database (physical replication). For CDC (logical replication), PostgreSQL needs to record the full before/after state of every row change. Setting this to `1` enables that mode.

**`wal_sender_timeout = 0`:** By default, PostgreSQL disconnects a WAL sender (like DMS) if it has been idle for 60 seconds. Setting this to `0` disables that timeout, preventing DMS from repeatedly reconnecting.

**`apply_method = "pending-reboot"`:** These settings require a database restart to take effect. After first applying Terraform, you need to reboot the RDS instance once for logical replication to activate.

---

### 4. RDS Subnet Group

```hcl
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-${var.environment}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
}
```

**What it is:** RDS requires a subnet group that tells it which subnets it can deploy into. By specifying both private subnets (in different AZs), RDS can choose the best one for primary placement and use the other for Multi-AZ standby.

---

### 5. RDS PostgreSQL Instance — The Source Database

```hcl
resource "aws_db_instance" "source" {
  identifier        = "${var.name_prefix}-${var.environment}-source-db"
  engine            = "postgres"
  engine_version    = "16.3"
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  parameter_group_name   = aws_db_parameter_group.postgres.name
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period = 7
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = !var.deletion_protection

  multi_az = var.multi_az
}
```

**In a real production scenario:** This would be your existing application's RDS database — not a database you create with Terraform. You would point DMS at your existing RDS endpoint. For this platform, we provision the source database as well so we have a complete, self-contained environment to test with.

**`storage_encrypted = true` + `kms_key_id`:** The database's storage volume (the physical disk) is encrypted using the platform KMS key.

**`backup_retention_period = 7`:** AWS takes daily automated snapshots and keeps the last 7 days. You can restore the database to any point in the last 7 days.

**`deletion_protection = var.deletion_protection`:** In production, this prevents anyone from deleting the database (even if they run `terraform destroy`). In dev, it is `false` so you can clean up resources easily.

**`skip_final_snapshot = !var.deletion_protection`:** In production, when a database IS deleted, RDS takes one final snapshot before deletion. In dev, this is skipped so `terraform destroy` completes quickly.

**`multi_az = var.multi_az`:** In production, Multi-AZ keeps a synchronous standby replica in a different AZ. If the primary fails, RDS automatically fails over with no data loss.

---

### 6. DMS Replication Subnet Group

```hcl
resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id = "${var.name_prefix}-${var.environment}-dms-subnet-group"
  subnet_ids                  = var.private_subnet_ids
}
```

Same concept as the RDS subnet group — tells DMS which private subnets to deploy its replication instance into.

---

### 7. DMS Replication Instance

```hcl
resource "aws_dms_replication_instance" "this" {
  replication_instance_id    = "${var.name_prefix}-${var.environment}-dms-ri"
  replication_instance_class = var.dms_instance_class
  engine_version             = "3.5.3"
  allocated_storage          = 50
  publicly_accessible        = false
  multi_az                   = var.multi_az
  auto_minor_version_upgrade = true

  replication_subnet_group_id = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids      = [aws_security_group.dms.id]
}
```

**What the replication instance is:** It is an EC2 instance (managed by AWS) that runs the DMS replication software. It connects to the source (RDS) and target (S3), reads changes, and writes them out.

**`publicly_accessible = false`:** The replication instance stays inside the VPC. No public internet access.

**`engine_version = "3.5.3"`:** DMS engine version. This determines what database sources and targets are supported and what bug fixes are included.

---

### 8. DMS Source Endpoint — Points at RDS

```hcl
resource "aws_dms_endpoint" "source" {
  endpoint_type = "source"
  engine_name   = "postgres"
  server_name   = aws_db_instance.source.address
  port          = 5432
  database_name = var.db_name
  username      = var.db_username
  password      = var.db_password
}
```

**What an endpoint is:** An endpoint is DMS's connection configuration. The source endpoint tells DMS where the source database is and how to authenticate.

**`server_name = aws_db_instance.source.address`:** Instead of hardcoding an IP address, we reference the RDS instance's hostname directly. Terraform resolves this automatically.

---

### 9. DMS Target Endpoint — S3 Bronze Bucket (Parquet)

```hcl
resource "aws_dms_endpoint" "target_s3" {
  endpoint_type = "target"
  engine_name   = "s3"

  s3_settings {
    bucket_name               = var.bronze_bucket_name
    bucket_folder             = "raw"
    service_access_role_arn   = var.dms_s3_role_arn
    compression_type          = "GZIP"
    data_format               = "parquet"
    parquet_version           = "parquet-2-0"
    date_partition_enabled    = true
    date_partition_sequence   = "YYYYMMDD"
    timestamp_column_name     = "_dms_timestamp"
    include_op_for_full_load  = true
    cdc_inserts_and_updates   = true
    cdc_deletes_option        = "all-deletes"
  }
}
```

**Key settings explained:**

| Setting | Value | Meaning |
|---|---|---|
| `data_format` | `parquet` | Write columnar Parquet files instead of CSV. Parquet is 5-10x smaller and 10-100x faster to query |
| `parquet_version` | `parquet-2-0` | Use Parquet v2 format, which supports more data types including timestamps with nanosecond precision |
| `compression_type` | `GZIP` | Compress Parquet files with GZIP. Reduces S3 storage costs by 60-80% |
| `date_partition_enabled` | `true` | Create separate folders for each day: `raw/orders/20240115/` |
| `date_partition_sequence` | `YYYYMMDD` | Folder naming format |
| `timestamp_column_name` | `_dms_timestamp` | Add a `_dms_timestamp` column to every record showing when DMS captured the change |
| `include_op_for_full_load` | `true` | Include the operation column (`I`/`U`/`D`) even for the initial full load |
| `cdc_inserts_and_updates` | `true` | Capture both inserts and updates (not just inserts) |

---

### 10. DMS Replication Task — Full Load + CDC

```hcl
resource "aws_dms_replication_task" "cdc" {
  migration_type = "full-load-and-cdc"

  table_mappings = jsonencode({
    rules = [{
      "rule-type"    = "selection"
      "rule-action"  = "include"
      "object-locator" = {
        "schema-name" = "%"   # % means all schemas
        "table-name"  = "%"   # % means all tables
      }
    }]
  })
}
```

**`migration_type = "full-load-and-cdc"`:** DMS performs two phases:

1. **Full load:** Copies the entire current state of all tables into Bronze. This creates the baseline.
2. **CDC (ongoing):** After the full load, DMS switches to reading the WAL and capturing changes in real time.

**`table_mappings`:** The `%` wildcard means "include all schemas and all tables." In production, you would narrow this to specific tables:
```json
"schema-name": "public",
"table-name": "orders"
```

**`replication_task_settings`:** Configures LOB (Large Object) handling, maximum sub-tasks for parallel full load, and CloudWatch logging.

---

## Module Inputs (Variables)

| Variable | Type | Default | Description |
|---|---|---|---|
| `environment` | string | — | `dev`, `staging`, or `prod` |
| `name_prefix` | string | — | Global naming prefix |
| `vpc_id` | string | — | VPC ID from `networking` module |
| `private_subnet_ids` | list(string) | — | Private subnet IDs from `networking` module |
| `kms_key_arn` | string | — | KMS key ARN from `iam-metadata` module |
| `bronze_bucket_name` | string | — | Bronze bucket name from `data-lake` module |
| `dms_s3_role_arn` | string | — | DMS S3 role ARN from `iam-metadata` module |
| `db_password` | string | — | RDS master password (sensitive — never commit this) |
| `db_name` | string | `appdb` | Database name on RDS |
| `db_username` | string | `dbadmin` | RDS master username |
| `db_instance_class` | string | `db.t3.micro` | RDS compute tier |
| `db_allocated_storage` | number | `20` | RDS disk size in GB |
| `dms_instance_class` | string | `dms.t3.micro` | DMS replication instance compute tier |
| `multi_az` | bool | `false` | Enable Multi-AZ for RDS + DMS |
| `deletion_protection` | bool | `false` | Protect RDS from accidental deletion |

---

## Sensitive Variables — How to Provide Passwords

**Never put passwords in your `.tf` files or commit them to Git.**

Provide them via:

**Option 1 — Environment variable:**
```bash
export TF_VAR_db_password="YourSecurePassword123!"
make apply dev
```

**Option 2 — tfvars file (excluded from git):**
```bash
# File: environments/dev/secret.tfvars  (added to .gitignore)
db_password            = "YourSecurePassword123!"
redshift_admin_password = "AnotherSecurePassword456!"

# Apply with:
terraform apply -var-file="secret.tfvars"
```

**Option 3 — AWS Secrets Manager (production best practice):**
Retrieve the password from Secrets Manager in your Terraform code using a `data "aws_secretsmanager_secret_version"` data source.

---

## Module Outputs

| Output | Description |
|---|---|
| `rds_endpoint` | RDS hostname — used by application teams to connect |
| `rds_port` | RDS port (5432) |
| `rds_identifier` | RDS instance identifier |
| `rds_security_group_id` | Security group ID — can be referenced by other modules that need RDS access |
| `dms_security_group_id` | DMS security group ID |
| `dms_replication_instance_arn` | DMS replication instance ARN |
| `dms_replication_task_arn` | DMS task ARN — used to start/stop the task via CLI or Airflow |

---

## How to Deploy

**Important:** Run the `iam-metadata` module first — DMS needs the `dms-vpc-role` and `dms-cloudwatch-logs-role` IAM roles to exist before creating a replication instance.

```bash
aws sso login --profile dev-admin

# From terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

### After First Apply — Enable CDC

After Terraform creates the RDS instance, logical replication requires a database reboot:

```bash
aws rds reboot-db-instance \
  --db-instance-identifier edp-dev-source-db \
  --profile dev-admin
```

Wait for the instance to be back in `available` state, then start the DMS task:

```bash
aws dms start-replication-task \
  --replication-task-arn <task_arn_from_terraform_output> \
  --start-replication-task-type start-replication \
  --profile dev-admin
```

---

## Validation Checklist

**RDS Console:**
- [ ] Instance `edp-dev-source-db` is in `available` state
- [ ] Engine: PostgreSQL 16.3
- [ ] Storage encrypted: Yes
- [ ] Multi-AZ: matches your variable setting
- [ ] Deletion protection: matches your variable setting
- [ ] Parameter group: `edp-dev-postgres16`

**DMS Console:**
- [ ] Replication instance `edp-dev-dms-ri` is in `available` state
- [ ] Source endpoint `edp-dev-source-endpoint` is in `successful` test state
- [ ] Target endpoint `edp-dev-bronze-s3-endpoint` is in `successful` test state
- [ ] Replication task `edp-dev-cdc-task` is visible

**S3 Console:**
- [ ] After starting the task, `raw/` prefix appears in the Bronze bucket
- [ ] Parquet files are being written under `raw/{schema}/{table}/{date}/`

---

## Files in This Module

| File | Purpose |
|---|---|
| `main.tf` | Security groups, RDS parameter group, RDS instance, DMS subnet group, DMS replication instance, DMS source + target endpoints, DMS replication task |
| `variables.tf` | Input variables (network, credentials, sizing, behavior flags) |
| `outputs.tf` | RDS endpoint, security group IDs, DMS ARNs |
