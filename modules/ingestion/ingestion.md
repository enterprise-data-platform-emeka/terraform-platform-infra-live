# Module: ingestion

**Location:** `terraform-platform-infra-live/modules/ingestion/`

**Depends on:** `networking` (vpc_id, private_subnet_ids), `iam-metadata` (kms_key_arn, dms_s3_role_arn), `data-lake` (bronze_bucket_name)

---

## What this module does

This module builds the entry point for data into the platform. It answers one question: how does data get from a PostgreSQL (a popular open-source relational database) application database into the S3 (Simple Storage Service) data lake?

The answer is CDC (Change Data Capture) using AWS DMS (Database Migration Service).

Instead of copying the full database every night, CDC captures every individual change as it happens: each row inserted, updated, or deleted. DMS reads these changes and writes them as Parquet files (a compact, column-organised file format) into the Bronze S3 bucket in near real time. This approach is faster, uses less storage, and keeps a precise record of exactly what changed and when.

---

## The ingestion architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    VPC (Virtual Private Cloud)                      │
│                        Private Subnets                              │
│                                                                     │
│   ┌──────────────────────────┐         ┌──────────────────────────┐ │
│   │   RDS PostgreSQL         │         │   DMS Replication        │ │
│   │   Source Database        │◄────────│   Instance               │ │
│   │                          │  reads  │                          │ │
│   │   Logical replication    │  WAL    │   Reads PostgreSQL WAL   │ │
│   │   enabled                │         │   Converts to Parquet    │ │
│   │   Security group         │         │   Writes to Bronze S3    │ │
│   │   allows DMS only        │         │                          │ │
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

PostgreSQL keeps an internal journal called the WAL (Write-Ahead Log). Every INSERT, UPDATE, and DELETE is written to this log before it is applied to the actual database tables. This is how PostgreSQL guarantees it can recover from a crash: even if the database restarts unexpectedly, the WAL contains a record of every operation that needs to be replayed.

DMS connects to PostgreSQL and reads this WAL log. For each change it finds, DMS captures:
- The full row of data after the change
- The operation type: `I` for Insert, `U` for Update, or `D` for Delete
- A timestamp recording when the change was captured

These records are written as Parquet files to the Bronze S3 bucket, organised by date.

**Example Bronze record for an INSERT:**

```
_dms_timestamp: 2024-01-15T10:00:00Z
Op: I
order_id: 12345
customer_id: 678
amount: 99.99
status: "pending"
```

**Example Bronze record for an UPDATE (the status changed to "shipped"):**

```
_dms_timestamp: 2024-01-15T14:30:00Z
Op: U
order_id: 12345
customer_id: 678
amount: 99.99
status: "shipped"
```

The Bronze bucket now has two records for `order_id 12345`: the original insert and the later update. Bronze never deletes or modifies anything. The Glue (AWS's managed data integration service) Silver job reads both records and produces one Silver record showing the current state: `status = "shipped"`.

---

## Resources created

### 1. Security group for RDS

A security group is a virtual firewall that controls what network traffic is allowed in and out of a service. AWS uses security groups instead of IP address rules wherever possible because IP addresses change but security group membership stays stable.

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
  source_security_group_id = aws_security_group.dms.id
  security_group_id        = aws_security_group.rds.id
}
```

Port 5432 is the default port PostgreSQL listens on. The `source_security_group_id` rule means: "Allow inbound TCP traffic on port 5432, but only from resources that are members of the DMS security group." This is more secure than allowing a specific IP address, because the DMS replication instance can restart and get a new IP address, but it always stays in the same security group.

Nothing else is allowed to connect to the RDS (Relational Database Service) instance. Not a laptop, not another service, only DMS.

---

### 2. Security group for DMS

```hcl
resource "aws_security_group" "dms" {
  name   = "${var.name_prefix}-${var.environment}-dms-sg"
  vpc_id = var.vpc_id
}
```

DMS needs to send traffic outbound to two places: port 5432 on RDS (to read the WAL log), and S3 (to write Parquet files). The S3 traffic goes through the S3 Gateway VPC (Virtual Private Cloud) Endpoint created in the networking module, so no internet access is needed for that. The RDS traffic stays inside the VPC.

---

### 3. RDS parameter group

A parameter group is a collection of database configuration settings. AWS applies these settings when the RDS instance starts. I create a custom parameter group instead of using the default one because I need to enable logical replication, which is off by default.

```hcl
resource "aws_db_parameter_group" "postgres" {
  name   = "${var.name_prefix}-${var.environment}-${local.pg_family}"
  family = local.pg_family

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

**`local.pg_family`:** The parameter group family name (for example, `postgres16`) is derived automatically from `var.db_engine_version` using `split(".", "16.6")[0]`. This means if the engine version variable is updated to `17.2`, the parameter group family updates to `postgres17` without any extra changes.

**`rds.logical_replication = 1`:** By default, PostgreSQL's WAL records just enough information to recover the database after a crash. This is called physical replication. For CDC, I need logical replication, which records the full before and after state of every row change so DMS can understand exactly what changed. Setting this to `1` switches PostgreSQL into logical replication mode.

**`wal_sender_timeout = 0`:** By default, PostgreSQL disconnects any WAL reader (like DMS) that has been idle for 60 seconds. If DMS gets disconnected, it has to reconnect and resume, which can cause brief gaps or duplicates. Setting this to `0` disables the timeout entirely, keeping the DMS connection stable.

**`apply_method = "pending-reboot"`:** These two settings require a full database restart to take effect. After the first `terraform apply`, I reboot the RDS instance once and then logical replication is active. I only have to do this once.

---

### 4. RDS subnet group

```hcl
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-${var.environment}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
}
```

RDS requires a subnet group before it can deploy. The subnet group tells RDS which subnets are available for placement. I pass both private subnets (from the networking module) so RDS can choose the right AZ (Availability Zone, which is an independent data centre within the same AWS region) for the primary instance and use the other for a standby in Multi-AZ mode.

---

### 5. RDS PostgreSQL instance

```hcl
resource "aws_db_instance" "source" {
  identifier        = "${var.name_prefix}-${var.environment}-source-db"
  engine            = "postgres"
  engine_version    = var.db_engine_version
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

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = !var.deletion_protection

  multi_az = var.multi_az
}
```

In a real production setup, the source database would already exist (it would be the application's existing database), and I would simply point DMS at it. For this platform I create an RDS instance as the source so I have a self-contained environment to test with. I can insert, update, and delete rows in this database and watch the changes flow through the pipeline.

**`storage_encrypted = true` and `kms_key_id`:** The physical disk that holds the database files is encrypted using the platform KMS key. If someone physically removed the storage from AWS's data centre, they would see only encrypted bytes.

**`backup_retention_period = var.backup_retention_period`:** AWS takes automated daily snapshots and keeps them for this many days. The default is 7 days. Production environments set this to 30 days for longer recovery windows.

**`deletion_protection = var.deletion_protection`:** In production this is `true`, which means Terraform and the AWS console both refuse to delete the database. This protects real data from being accidentally wiped. In dev it is `false` so I can run `terraform destroy` without manually disabling deletion protection first.

**`skip_final_snapshot = !var.deletion_protection`:** In production, when a database is deleted, AWS takes one final snapshot before deletion so I have a last backup. In dev, I skip this because it would slow down a `terraform destroy` during testing.

**`multi_az = var.multi_az`:** In production, Multi-AZ keeps a synchronous standby copy of the database in a different AZ. If the primary database fails, RDS automatically switches to the standby with no manual action needed. In dev, I set this to `false` to save costs.

---

### 6. DMS replication subnet group

```hcl
resource "aws_dms_replication_subnet_group" "this" {
  replication_subnet_group_id = "${var.name_prefix}-${var.environment}-dms-subnet-group"
  subnet_ids                  = var.private_subnet_ids
}
```

This works the same way as the RDS subnet group. DMS needs to know which private subnets it can deploy its replication instance into. I pass both private subnets so DMS can choose the right one.

---

### 7. DMS replication instance

```hcl
resource "aws_dms_replication_instance" "this" {
  replication_instance_id    = "${var.name_prefix}-${var.environment}-dms-ri"
  replication_instance_class = var.dms_instance_class
  allocated_storage          = var.dms_allocated_storage
  publicly_accessible        = false
  multi_az                   = var.multi_az
  auto_minor_version_upgrade = true

  replication_subnet_group_id = aws_dms_replication_subnet_group.this.id
  vpc_security_group_ids      = [aws_security_group.dms.id]
}
```

The replication instance is a managed EC2 (Elastic Compute Cloud) virtual machine that runs the DMS replication software. I do not SSH into it or manage it. AWS handles all the operating system maintenance. It reads from the RDS source, converts the WAL log entries into Parquet records, and writes them to the Bronze S3 bucket.

**`publicly_accessible = false`:** The replication instance stays inside the VPC. No public internet access.

**`engine_version = "3.5.3"`:** The DMS engine version determines which source and target database types are supported and which bug fixes are included.

**`auto_minor_version_upgrade = true`:** AWS automatically upgrades to new minor versions (like 3.5.3 to 3.5.4) during maintenance windows. Minor versions contain bug fixes and do not change how the engine works.

---

### 8. DMS source endpoint

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

An endpoint is DMS's connection configuration. The source endpoint tells DMS where the source database lives and how to authenticate. `server_name = aws_db_instance.source.address` references the RDS hostname directly from the Terraform resource, so I do not hardcode any IP addresses or hostnames.

---

### 9. DMS target endpoint (Bronze S3 bucket)

The AWS provider 5.x introduced a dedicated resource for S3 endpoints: `aws_dms_s3_endpoint`. In earlier provider versions this was configured using a nested `s3_settings` block inside `aws_dms_endpoint`, but that block was removed in provider 5. All S3 settings are now top-level attributes on `aws_dms_s3_endpoint`.

```hcl
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
```

The target endpoint tells DMS where to write the output and in what format.

| Setting | Value | What it means |
|---|---|---|
| `data_format` | `parquet` | Write Parquet files instead of CSV (Comma-Separated Values). Parquet is a columnar format that is 5 to 10 times smaller and much faster to query than CSV |
| `parquet_version` | `parquet-2-0` | Use Parquet version 2, which supports more data types including timestamps with nanosecond precision |
| `compression_type` | `GZIP` | Compress each Parquet file using GZIP (GNU Zip). This reduces S3 storage costs by 60 to 80 percent |
| `date_partition_enabled` | `true` | Create a separate folder for each day: `raw/orders/20240115/` |
| `date_partition_sequence` | `YYYYMMDD` | The date folder naming format: year, month, day |
| `timestamp_column_name` | `_dms_timestamp` | Add a column to every row recording when DMS captured the change |
| `include_op_for_full_load` | `true` | Include the operation column (I, U, D) even during the initial full data copy, not just during ongoing CDC |
| `cdc_inserts_and_updates` | `true` | Capture both inserts and updates during CDC (not just inserts) |
| `cdc_deletes_option` | `all-deletes` | Capture delete operations too, so I can track records that were removed from the source |

---

### 10. DMS replication task

```hcl
resource "aws_dms_replication_task" "cdc" {
  migration_type = "full-load-and-cdc"

  table_mappings = jsonencode({
    rules = [{
      "rule-type"    = "selection"
      "rule-action"  = "include"
      "object-locator" = {
        "schema-name" = "%"
        "table-name"  = "%"
      }
    }]
  })
}
```

The replication task is the actual job that reads from the source endpoint and writes to the target endpoint.

**`migration_type = "full-load-and-cdc"`:** DMS runs in two phases. First, it does a full load: it copies the entire current state of all tables into the Bronze bucket. This gives me a complete baseline. Second, after the full load is done, DMS switches to CDC mode and reads the WAL continuously, capturing every change as it happens.

**`table_mappings`:** The `%` wildcard means include all schemas and all tables. In production I would narrow this to specific tables. For example:

```json
"schema-name": "public",
"table-name": "orders"
```

But for development I include everything so I can test with any table I create in the source database.

**LOB (Large Object) handling:** The task settings also configure how DMS handles large column values (like long text fields or binary data). The default LOB mode allows DMS to fetch these in chunks if they are too large for a single transfer.

---

### 11. SSM parameter for the RDS password

```hcl
resource "aws_ssm_parameter" "db_password" {
  name        = "/edp/${var.environment}/rds/db_password"
  description = "RDS PostgreSQL master password — ${var.environment}"
  type        = "SecureString"
  value       = var.db_password
  key_id      = var.kms_key_arn
  tags        = local.common_tags
}
```

After Terraform applies, the RDS password is automatically stored in SSM (Systems Manager) Parameter Store at `/edp/{environment}/rds/db_password` as a `SecureString` encrypted with the platform KMS key. This means the password never needs to exist in a file anywhere. Any tool that needs it — the simulator, an Airflow DAG, a maintenance script — fetches it at runtime:

```bash
aws ssm get-parameter \
  --name /edp/dev/rds/db_password \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --profile dev-admin
```

The simulator's Makefile does this automatically when `ENV=dev`, `ENV=staging`, or `ENV=prod` is passed.

---

## Module inputs (variables)

| Variable | Type | Default | Description |
|---|---|---|---|
| `environment` | string | required | `dev`, `staging`, or `prod` |
| `name_prefix` | string | required | Short prefix for all resource names |
| `vpc_id` | string | required | VPC ID from the `networking` module |
| `private_subnet_ids` | list(string) | required | Private subnet IDs from the `networking` module |
| `kms_key_arn` | string | required | KMS key ARN (Amazon Resource Name) from the `iam-metadata` module |
| `bronze_bucket_name` | string | required | Bronze bucket name from the `data-lake` module |
| `dms_s3_role_arn` | string | required | DMS S3 role ARN from the `iam-metadata` module |
| `db_password` | string | required | RDS master password (stored in SSM after apply, never commit to Git) |
| `db_name` | string | `appdb` | Name of the database inside the RDS instance |
| `db_username` | string | `dbadmin` | RDS master username |
| `db_engine_version` | string | `16.6` | PostgreSQL engine version. Controls both the engine and the parameter group family |
| `db_instance_class` | string | `db.t3.micro` | RDS compute size (determines CPU and memory) |
| `db_allocated_storage` | number | `20` | RDS disk size in gigabytes |
| `backup_retention_period` | number | `7` | Days to retain automated RDS backups. Dev: 7, staging: 14, prod: 30 |
| `dms_instance_class` | string | `dms.t3.medium` | DMS replication instance compute size |
| `dms_allocated_storage` | number | `50` | DMS replication instance disk size in gigabytes |
| `multi_az` | bool | `false` | Enable Multi-AZ for RDS and DMS (recommended for production) |
| `deletion_protection` | bool | `false` | Protect RDS from accidental deletion (set to `true` in production) |

---

## Sensitive variables

`db_password` has no default and must be provided at apply time. Never put it in a `.tf` file or commit it to Git.

**Recommended — environment variable:**

```bash
export TF_VAR_db_password="YourSecurePassword123!"
make apply dev
```

Terraform reads any `TF_VAR_*` environment variable and maps it to the matching variable name. **After `apply` completes**, Terraform stores the password in SSM Parameter Store at `/edp/dev/rds/db_password`. From that point on, all tools (simulator, Airflow, scripts) fetch it from SSM — no password file ever needs to exist.

**Alternative — tfvars file (excluded from Git):**

```bash
# Create this file: environments/dev/secret.tfvars
# Add secret.tfvars to your .gitignore file

db_password = "YourSecurePassword123!"

# Then apply with:
terraform apply -var-file="secret.tfvars"
```

---

## Module outputs

| Output | Description |
|---|---|
| `rds_endpoint` | The RDS hostname. Application teams use this to connect their app to the database |
| `rds_port` | The RDS port (5432) |
| `rds_identifier` | The RDS instance identifier, used in CLI commands like the reboot command |
| `rds_security_group_id` | The security group ID. Other modules can reference this if they need to allow traffic to RDS |
| `dms_security_group_id` | The DMS security group ID |
| `dms_replication_instance_arn` | The DMS replication instance ARN |
| `dms_replication_task_arn` | The DMS task ARN (Amazon Resource Name). I pass this to the Airflow DAG so it can start and monitor the task |
| `ssm_db_password_path` | The SSM parameter path where the RDS password is stored: `/edp/{env}/rds/db_password` |

---

## How to deploy

**Important:** Run the `iam-metadata` module before this one. The DMS replication instance creation requires `dms-vpc-role` and `dms-cloudwatch-logs-role` to already exist in the AWS account. If they do not exist, the replication instance creation fails.

```bash
aws sso login --profile dev-admin
```

SSO (Single Sign-On) refreshes my temporary AWS credentials before I run any Terraform command.

```bash
# From inside terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

### After the first apply: enable CDC

The logical replication parameter group setting requires a database restart to take effect. After the first `terraform apply`, I reboot the RDS instance:

```bash
aws rds reboot-db-instance \
  --db-instance-identifier edp-dev-source-db \
  --profile dev-admin
```

I wait for the instance to return to `available` status in the RDS console. This usually takes 2 to 3 minutes.

### Starting the DMS task

Terraform creates the DMS task but does not start it. I start it manually using the CLI (Command Line Interface):

```bash
aws dms start-replication-task \
  --replication-task-arn <task_arn_from_terraform_output> \
  --start-replication-task-type start-replication \
  --profile dev-admin
```

The task ARN appears in the Terraform output after `make apply dev`. The `start-replication` type means start from the beginning, running the full load first and then switching to CDC.

---

## Validation checklist

After `terraform apply` and after starting the task, I verify the following in the AWS console:

**RDS (Relational Database Service) console:**
- [ ] Instance `edp-dev-source-db` is in `available` state
- [ ] Engine: PostgreSQL 16.6 (or the version set in `db_engine_version`)
- [ ] Storage encrypted: Yes
- [ ] Parameter group: `edp-dev-postgres16` (family derived from engine version)
- [ ] Multi-AZ: matches the variable setting

**SSM (Systems Manager) console:**
- [ ] Parameter `/edp/dev/rds/db_password` exists as a `SecureString`

**DMS (Database Migration Service) console:**
- [ ] Replication instance `edp-dev-dms-ri` is in `available` state
- [ ] Source endpoint connection test: successful
- [ ] Target endpoint connection test: successful
- [ ] Replication task `edp-dev-cdc-task` is visible

**S3 (Simple Storage Service) console:**
- [ ] After starting the task, a `raw/` folder appears in the Bronze bucket
- [ ] Parquet files appear under `raw/{schema}/{table}/{date}/`

---

## What comes next

After ingestion is running and data is landing in Bronze:

1. The **`processing` module** sets up Glue jobs and the Athena (AWS's serverless SQL query engine) workgroup. The Glue job reads Bronze, resolves CDC operations, validates the schema, and writes clean records to Silver.
2. The **`serving` module** sets up Redshift Serverless, which connects to the Gold layer via Spectrum for analyst queries and dashboard connections.
3. The **`orchestration` module** sets up MWAA (Amazon Managed Workflows for Apache Airflow) to schedule and monitor the entire pipeline automatically.

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | Security groups, RDS parameter group, RDS instance, DMS subnet group, DMS replication instance, DMS source and target endpoints, DMS replication task |
| `variables.tf` | Input variable declarations including sensitive password variables |
| `outputs.tf` | RDS endpoint, security group IDs, DMS ARNs |
