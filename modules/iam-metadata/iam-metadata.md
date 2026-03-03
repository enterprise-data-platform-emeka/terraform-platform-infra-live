# Module: iam-metadata

**Location:** `terraform-platform-infra-live/modules/iam-metadata/`

**Part of:** Terraform Platform Infra — Foundation Layer

**Depends on:** `data-lake` module (needs bucket names)

---

## What This Module Does

This module creates the **security and metadata foundation** for the entire platform. Every other service (Glue, MWAA, Redshift, DMS) needs two things before it can do anything:

1. **Permission to act** — An IAM Role that says "this service is allowed to read S3 / write CloudWatch / call KMS"
2. **Encryption keys** — A KMS Key that encrypts data at rest so it is unreadable without authorization
3. **A metadata catalog** — Glue Catalog databases that store the schema (column names, data types) for Bronze/Silver/Gold data, so Athena and Redshift Spectrum can query it

Think of this module as issuing the **ID badges, key cards, and filing system** for everyone who works in the platform building.

---

## Why IAM Roles Instead of IAM Users?

**IAM Users** have permanent credentials (access keys). If leaked, they give indefinite access.

**IAM Roles** are assumed temporarily by AWS services. They generate short-lived credentials automatically. There are no static secrets to leak.

Each service in this platform has exactly one dedicated role with exactly the permissions it needs — nothing more. This is the **principle of least privilege**.

| Service | Role Created | What It Can Do |
|---|---|---|
| AWS Glue | `edp-{env}-glue-role` | Read/write Bronze, Silver, Gold, Quarantine S3; KMS decrypt/encrypt; Glue Catalog operations |
| Amazon MWAA | `edp-{env}-mwaa-role` | Read the DAGs S3 bucket; write CloudWatch logs; call Glue StartJobRun; KMS decrypt |
| Redshift Serverless | `edp-{env}-redshift-role` | Read Silver and Gold S3 (for Spectrum); KMS decrypt; read Glue Catalog |
| AWS DMS | `edp-{env}-dms-s3-role` | Write to Bronze S3; KMS encrypt (for CDC output files) |
| AWS DMS (VPC) | `dms-vpc-role` | Required fixed name — allows DMS to create network interfaces in your VPC |
| AWS DMS (Logs) | `dms-cloudwatch-logs-role` | Required fixed name — allows DMS to write to CloudWatch |

---

## Resources Created

### 1. KMS Key — The Master Encryption Key

```hcl
resource "aws_kms_key" "platform" {
  description             = "EDP platform encryption key (${var.environment})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${var.name_prefix}-${var.environment}-platform"
  target_key_id = aws_kms_key.platform.key_id
}
```

**What KMS is:** AWS Key Management Service (KMS) manages cryptographic keys. A KMS key is essentially a very secure password that AWS uses to encrypt and decrypt your data.

**`deletion_window_in_days = 30`:** When you delete a KMS key, AWS does not immediately destroy it. It waits 30 days (the maximum). This gives you a window to recover if a key was deleted by mistake. During this window, you can cancel the deletion.

**`enable_key_rotation = true`:** AWS automatically rotates (regenerates) the underlying key material every year. This is a security best practice — even if old key material was compromised, it becomes useless after rotation.

**`aws_kms_alias`:** An alias is a human-readable name for the key (like `alias/edp-dev-platform`) because KMS keys otherwise have non-human-readable IDs like `arn:aws:kms:eu-central-1:123456789:key/abc-123-xyz`.

**This key is used by:** DMS (encrypts RDS storage), Glue (encrypts job bookmarks, CloudWatch logs, S3 writes), MWAA (encrypts environment variables), Redshift (encrypts namespace).

---

### 2. Glue Data Catalog Databases

```hcl
resource "aws_glue_catalog_database" "bronze" {
  name        = "${var.name_prefix}_${var.environment}_bronze"
  description = "Bronze layer – raw CDC-ingested data"
}

resource "aws_glue_catalog_database" "silver" { ... }
resource "aws_glue_catalog_database" "gold"   { ... }
```

**What the Glue Catalog is:** The AWS Glue Data Catalog is a metadata repository — it stores the schema (table name, column names, data types, file format, S3 location) for your data. Think of it as the table of contents for your data lake.

**Why it matters:** Amazon Athena and Redshift Spectrum do not know how to query raw Parquet files on their own. They need the Glue Catalog to tell them: "The file at `s3://edp-dev-bronze/raw/orders/` is a Parquet table with columns `order_id (string)`, `amount (decimal)`, `created_at (timestamp)`."

Without Catalog entries, Athena and Spectrum cannot see the data.

**Three databases:** One per medallion layer. Glue crawlers (or manual table definitions) will populate these databases with table schemas after data has landed in the corresponding S3 buckets.

---

### 3. IAM Role — Glue

```hcl
resource "aws_iam_role" "glue" {
  name               = "${var.name_prefix}-${var.environment}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}
```

**The assume role policy (trust policy):**

```hcl
data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}
```

This says: "Only the AWS Glue service is allowed to assume this role." No human, no other service, only Glue.

**Two policies attached:**

1. **`AWSGlueServiceRole`** (AWS-managed): Gives Glue general permissions it needs to function — create CloudWatch log groups, describe VPC resources, etc.

2. **`glue_data_access`** (custom inline): Grants S3 read/write on Bronze, Silver, Gold, Quarantine buckets + KMS decrypt/encrypt + Glue Catalog operations (GetTable, CreateTable, BatchCreatePartition, etc.)

**Why separate policies?** The AWS-managed `AWSGlueServiceRole` covers Glue's operational needs. The custom policy covers data-specific permissions. Separation makes it clear which permissions are Glue infrastructure vs. data access.

---

### 4. IAM Role — MWAA (Airflow)

```hcl
resource "aws_iam_role" "mwaa" {
  name               = "${var.name_prefix}-${var.environment}-mwaa-role"
  assume_role_policy = data.aws_iam_policy_document.mwaa_assume_role.json
}
```

**Trust policy:** Both `airflow.amazonaws.com` and `airflow-env.amazonaws.com` can assume this role. MWAA uses two sub-services internally.

**Permissions granted:**

| Permission Group | Why Needed |
|---|---|
| S3 read on DAGs bucket | Airflow reads DAG Python files from S3 |
| CloudWatch logs | Airflow writes scheduler, worker, and webserver logs |
| CloudWatch metrics | Airflow publishes operational metrics |
| SQS on `airflow-celery-*` | MWAA uses Celery internally for task queuing |
| KMS decrypt/encrypt | Encrypts Airflow environment variables and connections |
| Glue StartJobRun, GetJobRun | Airflow DAGs trigger Glue jobs and wait for completion |

**The DAGs bucket ARN is constructed predictably:**

```hcl
"arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags"
```

This matches the exact bucket name the `orchestration` module will create. Both modules use the same naming formula.

---

### 5. IAM Role — Redshift Serverless

```hcl
resource "aws_iam_role" "redshift" {
  name               = "${var.name_prefix}-${var.environment}-redshift-role"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume_role.json
}
```

**Trust policy:** Both `redshift.amazonaws.com` and `redshift-serverless.amazonaws.com` can assume this role.

**Permissions granted:**

| Permission | Why Needed |
|---|---|
| S3 GetObject + ListBucket on Gold and Silver | Redshift Spectrum reads external tables from S3 |
| KMS Decrypt + GenerateDataKey | Decrypt data files that were encrypted by Glue |
| Glue GetDatabase + GetTable + GetPartitions | Spectrum queries the Glue Catalog to get table schemas |

**What Redshift Spectrum does:** Spectrum allows Redshift to query data that lives in S3 (not inside Redshift's internal storage). A SQL query like `SELECT * FROM spectrum.orders LIMIT 100` reads directly from the Gold S3 bucket via the Glue Catalog. No data loading step required.

---

### 6. IAM Roles — DMS (Three Roles)

DMS requires three separate IAM roles:

**`dms-vpc-role`** (fixed name required by AWS DMS):
```hcl
resource "aws_iam_role" "dms_vpc" {
  name = "dms-vpc-role"   # This exact name is required by the DMS service
  ...
}
resource "aws_iam_role_policy_attachment" "dms_vpc" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}
```
When DMS creates a replication instance inside your VPC, it needs to create Elastic Network Interfaces (ENIs). This role gives DMS permission to do that. The name `dms-vpc-role` is hardcoded into the DMS service — it looks for exactly this role name in your account.

**`dms-cloudwatch-logs-role`** (fixed name required by AWS DMS):
Allows DMS to write replication logs to CloudWatch. Again, the name is required.

> **Important note:** If these roles already exist in your AWS account (from a previous deployment), Terraform will fail when trying to create them again. In that case, import them:
> ```bash
> terraform import module.iam_metadata.aws_iam_role.dms_vpc dms-vpc-role
> terraform import module.iam_metadata.aws_iam_role.dms_cloudwatch dms-cloudwatch-logs-role
> ```

**`{name_prefix}-{env}-dms-s3-role`** (custom name):
Grants DMS permission to write Parquet files to the Bronze S3 bucket and use KMS to encrypt those files. This is the role DMS uses when running the replication task.

---

## Module Inputs (Variables)

| Variable | Type | Description |
|---|---|---|
| `environment` | string | Environment name: `dev`, `staging`, or `prod` |
| `name_prefix` | string | Global naming prefix (e.g., `edp`) |
| `bronze_bucket_name` | string | Bronze bucket name (from `data-lake` outputs) |
| `silver_bucket_name` | string | Silver bucket name (from `data-lake` outputs) |
| `gold_bucket_name` | string | Gold bucket name (from `data-lake` outputs) |
| `quarantine_bucket_name` | string | Quarantine bucket name (from `data-lake` outputs) |

---

## Module Outputs

| Output | Used By |
|---|---|
| `kms_key_arn` | All modules that encrypt data (ingestion, processing, serving, orchestration) |
| `kms_key_id` | Available for reference |
| `glue_role_arn` | `processing` module (assigns role to Glue security config) |
| `mwaa_role_arn` | `orchestration` module (assigns role to MWAA environment) |
| `redshift_role_arn` | `serving` module (assigns role to Redshift namespace) |
| `dms_s3_role_arn` | `ingestion` module (assigns role to DMS S3 endpoint) |
| `glue_catalog_database_bronze` | Future Glue crawlers and Athena queries |
| `glue_catalog_database_silver` | Future Glue crawlers and Athena queries |
| `glue_catalog_database_gold` | Future Glue crawlers and Athena queries |

---

## How to Deploy

This module is deployed as part of an environment (not standalone).

```bash
# Login
aws sso login --profile dev-admin

# From terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

The environment's `main.tf` calls this module like:

```hcl
module "iam_metadata" {
  source                 = "../../modules/iam-metadata"
  environment            = var.environment
  name_prefix            = var.name_prefix
  bronze_bucket_name     = module.data_lake.bronze_bucket_name
  silver_bucket_name     = module.data_lake.silver_bucket_name
  gold_bucket_name       = module.data_lake.gold_bucket_name
  quarantine_bucket_name = module.data_lake.quarantine_bucket_name
}
```

Note that `bronze_bucket_name` comes from `module.data_lake.bronze_bucket_name` — the output of the data-lake module. Terraform resolves this dependency automatically and ensures data-lake is applied before iam-metadata.

---

## Validation Checklist

After `terraform apply`, verify in the AWS Console:

**KMS Console:**
- [ ] Key with alias `alias/edp-dev-platform` exists
- [ ] Key rotation: Enabled
- [ ] Key state: Enabled

**IAM Console → Roles:**
- [ ] `edp-dev-glue-role` exists, trusted by `glue.amazonaws.com`
- [ ] `edp-dev-mwaa-role` exists, trusted by `airflow.amazonaws.com`
- [ ] `edp-dev-redshift-role` exists, trusted by `redshift-serverless.amazonaws.com`
- [ ] `edp-dev-dms-s3-role` exists, trusted by `dms.amazonaws.com`
- [ ] `dms-vpc-role` exists
- [ ] `dms-cloudwatch-logs-role` exists

**Glue Console → Databases:**
- [ ] `edp_dev_bronze` database exists
- [ ] `edp_dev_silver` database exists
- [ ] `edp_dev_gold` database exists

---

## Files in This Module

| File | Purpose |
|---|---|
| `main.tf` | KMS key, Glue Catalog databases, and all IAM roles + policies |
| `variables.tf` | Input variables (environment, name_prefix, bucket names) |
| `outputs.tf` | Exports KMS ARN, all role ARNs, and Glue database names |
