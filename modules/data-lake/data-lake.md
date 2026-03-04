# Module: data-lake

**Location:** `terraform-platform-infra-live/modules/data-lake/`

**Depends on:** `networking` module

---

## What this module does

This module creates the storage foundation of the Enterprise Data Platform: five S3 (Simple Storage Service) buckets organized in the Medallion Architecture pattern.

Think of these buckets like shelves in a warehouse. Each shelf holds a specific type of data at a specific stage of processing. Data moves from the raw shelf (Bronze), through cleaning (Silver), to analytics-ready aggregations (Gold). Bad records get a separate shelf (Quarantine) rather than being thrown away invisibly. And query results get their own shelf (Athena Results).

---

## What is Medallion Architecture?

Medallion Architecture is an industry-standard pattern for organizing data in a data lake. It uses three or more layers, named after metals by quality, to represent data at different stages of transformation.

```
Raw CDC (Change Data Capture) Data
     │
     ▼
┌─────────────┐
│   BRONZE    │  Immutable. Exactly what arrived from the source.
│  (Raw)      │  I never modify or delete anything here.
└──────┬──────┘
       │
       ├──────────────────────────────────────────────┐
       │                                              │
       ▼                                              ▼
┌─────────────┐                              ┌─────────────────┐
│   SILVER    │  Valid records only.         │   QUARANTINE    │
│  (Cleaned)  │  Deduplicated.               │  (Invalid)      │
│             │  CDC resolved into           │  Failed schema  │
│             │  current state.              │  validation.    │
└──────┬──────┘                              └─────────────────┘
       │
       ▼
┌─────────────┐
│    GOLD     │  Business-level aggregations.
│ (Analytics) │  Pre-computed summaries.
│             │  Ready for dashboards.
└─────────────┘

Plus:

┌─────────────────────┐
│   ATHENA RESULTS    │  Query output files from Athena SQL.
│                     │  Required by the Athena workgroup config.
└─────────────────────┘
```

---

## Resources created

### Five S3 buckets

```hcl
resource "aws_s3_bucket" "bronze"         { bucket = local.bronze_bucket }
resource "aws_s3_bucket" "silver"         { bucket = local.silver_bucket }
resource "aws_s3_bucket" "gold"           { bucket = local.gold_bucket }
resource "aws_s3_bucket" "quarantine"     { bucket = local.quarantine_bucket }
resource "aws_s3_bucket" "athena_results" { bucket = local.athena_results_bucket }
```

**Naming pattern:** `{name_prefix}-{environment}-{account_id}-{layer}`

Example: `edp-dev-123456789012-bronze`

The AWS account ID is included because S3 bucket names are globally unique across all AWS accounts worldwide. Including the account ID guarantees my bucket name does not conflict with anyone else's bucket.

---

### Bronze bucket

**Purpose:** Receives raw CDC (Change Data Capture) events from DMS (Database Migration Service) exactly as they arrived from PostgreSQL.

**Immutability rule:** Nothing in Bronze is ever modified or deleted after landing. If data was ingested incorrectly, I fix the pipeline logic and re-ingest. I do not touch Bronze. This makes Bronze the platform's source of truth.

**What files look like inside:**

```
bronze/
  raw/
    public/
      orders/
        20240115/
          LOAD00000001.parquet
          20240115-100000-00001.parquet
```

---

### Silver bucket

**Purpose:** Holds validated, deduplicated, CDC-resolved records.

A Glue PySpark job reads Bronze, merges CDC (Change Data Capture) operations (INSERT, UPDATE, DELETE) into the current state of each record, validates the schema, and writes clean records here.

**What "CDC resolved" means:** If a record was inserted on Monday, updated Tuesday, and updated again Wednesday, the Bronze bucket has three separate files recording each event. Silver contains one record showing Wednesday's final values. The full change history is preserved in Bronze.

---

### Gold bucket

**Purpose:** Holds pre-aggregated, business-level datasets ready for analysts and dashboards.

A dbt (data build tool) job reads Silver data via Athena and writes aggregated results here. Examples:
- `daily_revenue_by_region/`
- `monthly_active_customers/`
- `product_inventory_summary/`

---

### Quarantine bucket

**Purpose:** Holds records that failed Silver validation.

Instead of silently dropping bad data, the Glue job writes rejected records here with metadata explaining why they were rejected: missing required field, wrong data type, referential integrity failure, etc.

I check Quarantine regularly to:
1. Understand data quality problems at the source
2. Fix the source system sending bad data
3. Re-process fixed records back through Bronze and then Silver

---

### Athena results bucket

**Purpose:** Amazon Athena (AWS's serverless SQL query engine) requires a designated S3 location to write query results. Every SQL query run through Athena writes its output file here.

This bucket is configured in the Athena workgroup (created in the `processing` module) to make sure all queries use this location.

---

### Encryption applied to all five buckets

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "all" {
  for_each = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    quarantine     = aws_s3_bucket.quarantine.id
    athena_results = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

`for_each` loops over a map of bucket names and creates one encryption configuration per bucket. This avoids repeating the same block five times.

AES256 (Advanced Encryption Standard with 256-bit keys) encrypts every file stored in these buckets. This is standard enterprise practice. If someone gained unauthorized access to the physical storage where S3 lives, they would see only encrypted bytes, not readable data.

Note: This uses AWS-managed keys (SSE-S3). The `iam-metadata` module creates a customer-managed KMS (Key Management Service) key used for services that need more granular key control, like Glue and DMS.

---

### Versioning applied to all five buckets

```hcl
resource "aws_s3_bucket_versioning" "all" {
  for_each = { ... }

  versioning_configuration {
    status = "Enabled"
  }
}
```

With versioning enabled, S3 keeps every version of every object ever written. If I overwrite `orders/2024-01-15/data.parquet`, S3 keeps the old version too.

This matters for a data lake because:
1. **Recovery:** If a Glue job writes bad data to Silver, I can roll back to the previous version of the files without re-running from Bronze
2. **Audit trail:** I can see the history of how data changed over time
3. **Protection:** Prevents accidental deletion from destroying data permanently

---

### Public access block applied to all five buckets

```hcl
resource "aws_s3_bucket_public_access_block" "all" {
  for_each = { ... }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

This is a four-way lock that prevents any public access to these buckets under any circumstances.

| Setting | What it blocks |
|---|---|
| `block_public_acls` | Blocks any new ACL (Access Control List) that grants public access |
| `block_public_policy` | Blocks any bucket policy that grants public access |
| `ignore_public_acls` | Makes S3 ignore any existing ACLs that grant public access |
| `restrict_public_buckets` | Makes S3 ignore any existing policies that grant public access |

I set all four because each one covers a different way that public access could accidentally be granted. Setting all four makes the protection airtight.

---

## Naming and local variables

```hcl
data "aws_caller_identity" "current" {}

locals {
  bronze_bucket         = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-bronze"
  silver_bucket         = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-silver"
  gold_bucket           = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-gold"
  quarantine_bucket     = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-quarantine"
  athena_results_bucket = "${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-athena-results"
}
```

`data "aws_caller_identity"` is a data source. It fetches the current AWS account ID at plan time without creating any resources. Terraform calls the AWS STS (Security Token Service) API to get this value.

`locals` are intermediate computed values used inside the module. They are not inputs or outputs. Using locals avoids repeating the same naming formula five times.

---

## Module inputs (variables)

| Variable | Type | Default | Description |
|---|---|---|---|
| `environment` | string | (required) | Environment name: `dev`, `staging`, or `prod` |
| `force_destroy` | bool | `false` | If `true`, allows bucket deletion even when it contains files |
| `name_prefix` | string | (required) | Prefix for all resource names, for example `edp` |

**`force_destroy` explained:**

In **dev**, I set this to `true`. This lets me run `terraform destroy` to clean up all resources including the S3 buckets even if they have data in them. This is important during development when I want to reset everything quickly.

In **staging and prod**, I set this to `false`. This prevents `terraform destroy` from deleting buckets that contain real data. Terraform will refuse to delete a non-empty bucket, protecting important data from accidental deletion.

---

## Module outputs

| Output | What it contains | Used by |
|---|---|---|
| `bronze_bucket_name` | Full S3 bucket name | `iam-metadata`, `ingestion`, `processing` |
| `silver_bucket_name` | Full S3 bucket name | `iam-metadata`, `processing`, `serving` |
| `gold_bucket_name` | Full S3 bucket name | `iam-metadata`, `serving` |
| `quarantine_bucket_name` | Full S3 bucket name | `iam-metadata` |
| `athena_results_bucket` | Full S3 bucket name | `processing` |

No other module should hardcode a bucket name. Instead, they reference these outputs:

```hcl
# In the environment's main.tf:
module "iam_metadata" {
  source             = "../../modules/iam-metadata"
  bronze_bucket_name = module.data_lake.bronze_bucket_name  # from this module
  silver_bucket_name = module.data_lake.silver_bucket_name
  ...
}
```

This creates an explicit dependency. Terraform knows it must create the data-lake buckets before creating the IAM roles that reference them.

---

## How to deploy

This module is deployed as part of an environment, not standalone.

```bash
aws sso login --profile dev-admin

# Using the Makefile from inside terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

Or manually:

```bash
cd terraform-platform-infra-live/environments/dev
terraform init
terraform plan
terraform apply
```

---

## Validation checklist

After `terraform apply`, I verify the following in the AWS console:

**S3 Console:**
- [ ] `edp-dev-<account_id>-bronze` exists
- [ ] `edp-dev-<account_id>-silver` exists
- [ ] `edp-dev-<account_id>-gold` exists
- [ ] `edp-dev-<account_id>-quarantine` exists
- [ ] `edp-dev-<account_id>-athena-results` exists

**For each bucket:**
- [ ] Encryption: Server-side encryption (AES256) is enabled
- [ ] Versioning: Enabled
- [ ] Block public access: All four settings are ON
- [ ] Tags: `Environment`, `ManagedBy`, `Project`, `AccountID` are set

---

## Environment differences

| Setting | dev | staging | prod |
|---|---|---|---|
| `force_destroy` | `true` | `false` | `false` |
| Bucket naming | `-dev-` | `-staging-` | `-prod-` |
| Tags | `Environment = dev` | `Environment = staging` | `Environment = prod` |

Everything else is identical. This is the point of using modules: one codebase, three environments.

---

## What comes next

After the data lake is deployed:

1. **`iam-metadata` module** - Creates IAM roles that grant Glue, MWAA, Redshift, and DMS access to these specific buckets
2. **`ingestion` module** - Sets up DMS to write CDC data into the Bronze bucket
3. **`processing` module** - Sets up Glue and Athena to read Bronze and write Silver and Gold

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | All S3 bucket resources, encryption, versioning, and public access blocks |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Exports all five bucket names for use by other modules |
