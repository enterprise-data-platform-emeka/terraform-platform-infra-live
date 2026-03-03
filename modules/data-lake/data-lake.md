# Module: data-lake

**Location:** `terraform-platform-infra-live/modules/data-lake/`

**Part of:** Terraform Platform Infra — Data Platform Layer

---

## What This Module Does

This module creates the **storage foundation** of the Enterprise Data Platform — five S3 buckets organized in the Medallion Architecture pattern.

Think of these buckets as the shelves in a warehouse. Each shelf holds a specific type of data at a specific stage of processing. Data moves from the raw shelf (Bronze) through cleaning (Silver) to analytics-ready (Gold).

---

## What is the Medallion Architecture?

The Medallion Architecture is an industry-standard pattern for organizing data in a data lake. It uses three or more layers (named after metals by quality) to represent data at different stages of quality and transformation.

```
Raw CDC Data
     │
     ▼
┌─────────────┐
│   BRONZE    │  Immutable. Exactly what arrived from the source.
│  (Raw)      │  Never modify. Never delete.
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
│    GOLD     │  Business-level aggregates.
│ (Analytics) │  Pre-computed summaries.
│             │  Ready for dashboards.
└─────────────┘

Plus:

┌─────────────────────┐
│   ATHENA RESULTS    │  Query output files from Athena SQL.
│                     │  Required by Athena workgroup config.
└─────────────────────┘
```

---

## Resources Created

### 1–5. Five S3 Buckets

```hcl
resource "aws_s3_bucket" "bronze"         { bucket = local.bronze_bucket }
resource "aws_s3_bucket" "silver"         { bucket = local.silver_bucket }
resource "aws_s3_bucket" "gold"           { bucket = local.gold_bucket }
resource "aws_s3_bucket" "quarantine"     { bucket = local.quarantine_bucket }
resource "aws_s3_bucket" "athena_results" { bucket = local.athena_results_bucket }
```

**Naming pattern:** `{name_prefix}-{environment}-{account_id}-{layer}`

Example: `edp-dev-123456789012-bronze`

The AWS account ID is included because **S3 bucket names are globally unique** across all AWS accounts worldwide. Including the account ID guarantees your bucket name does not conflict with anyone else's bucket.

#### Bronze Bucket

**Purpose:** Receives raw CDC (Change Data Capture) events from DMS exactly as they arrived from PostgreSQL.

**Immutability rule:** Nothing in Bronze is ever modified or deleted after landing. If data was ingested incorrectly, you fix the pipeline logic and re-ingest — you do not touch Bronze. This makes Bronze the platform's source of truth.

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

#### Silver Bucket

**Purpose:** Holds validated, deduplicated, CDC-resolved records.

A Glue PySpark job reads Bronze, merges CDC operations (INSERT/UPDATE/DELETE) into the current state of each record, validates the schema, and writes clean records here.

**What "CDC resolved" means:** If a record was inserted on Monday, updated Tuesday, and updated again Wednesday, the Bronze bucket has three separate files recording each event. The Silver layer contains one record with Wednesday's final values. The history of changes is represented by the Bronze layer.

#### Gold Bucket

**Purpose:** Holds pre-aggregated, business-level datasets ready for analysts and dashboards.

A dbt job reads Silver data via Athena and writes aggregated SQL results here. Examples:
- `daily_revenue_by_region/`
- `monthly_active_customers/`
- `product_inventory_summary/`

#### Quarantine Bucket

**Purpose:** Holds records that failed Silver validation.

Instead of silently dropping bad data, the Glue job writes it here with metadata explaining why it was rejected (missing required field, wrong data type, referential integrity failure, etc.).

Data engineers review Quarantine regularly to:
1. Understand data quality problems at the source
2. Fix the source system sending bad data
3. Re-process fixed records back through Bronze → Silver

#### Athena Results Bucket

**Purpose:** Amazon Athena requires a designated S3 location to write query results. Every SQL query run through Athena writes its output CSV/Parquet file here.

This bucket is configured in the Athena workgroup (in the `processing` module) to enforce all queries use this location.

---

### Encryption — Applied to All 5 Buckets

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

**What `for_each` does:** Instead of writing the same encryption block five times, `for_each` loops over a map of bucket names. Terraform creates one encryption configuration resource per bucket. This avoids repetition and makes the code easier to maintain.

**AES256 encryption:** Every file stored in these buckets is encrypted using the AES-256 algorithm. This is standard enterprise practice. If someone gained unauthorized access to the physical storage where S3 lives, they would see only encrypted bytes.

Note: This uses AWS-managed keys (SSE-S3). The `iam-metadata` module creates a customer-managed KMS key that is used for services that need more granular key control (Glue, DMS, Redshift).

---

### Versioning — Applied to All 5 Buckets

```hcl
resource "aws_s3_bucket_versioning" "all" {
  for_each = { ... }

  versioning_configuration {
    status = "Enabled"
  }
}
```

**What versioning does:** When versioning is enabled, S3 keeps every version of every object ever written. If you overwrite `orders/2024-01-15/data.parquet`, S3 keeps the old version too.

**Why this matters for a data lake:**
1. **Recovery:** If a Glue job writes bad data to Silver, you can roll back to the previous version of the files without re-running from Bronze
2. **Audit trail:** You can see the history of how data changed over time
3. **Protection:** Prevents accidental deletion from destroying data permanently

---

### Public Access Block — Applied to All 5 Buckets

```hcl
resource "aws_s3_bucket_public_access_block" "all" {
  for_each = { ... }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

**What this does:** This is a four-way lock that prevents any public access to these buckets under any circumstances.

| Setting | What it blocks |
|---|---|
| `block_public_acls` | Blocks any new ACL (access control list) that grants public access |
| `block_public_policy` | Blocks any bucket policy that grants public access |
| `ignore_public_acls` | Makes S3 ignore any existing ACLs that grant public access |
| `restrict_public_buckets` | Makes S3 ignore any existing policies that grant public access |

**Why all four?** Each setting covers a different attack vector. Setting all four ensures no misconfiguration or future change can accidentally make data public.

---

## Naming and Local Variables

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

**`data "aws_caller_identity"`:** This is a data source — it fetches the current AWS account ID at plan time without creating any resources. Terraform calls the AWS STS API to get this value.

**`locals`:** Local values are computed values used inside the module. They are not inputs or outputs — they are intermediate values that avoid repetition.

---

## Module Inputs (Variables)

| Variable | Type | Default | Description |
|---|---|---|---|
| `environment` | string | — | Environment name: `dev`, `staging`, or `prod` |
| `force_destroy` | bool | `false` | If `true`, allows bucket deletion even when non-empty |
| `name_prefix` | string | — | Prefix for all resource names (e.g., `edp`) |

**`force_destroy` explained:**

In **dev**, set to `true`. This lets you run `terraform destroy` to clean up all resources including the S3 buckets (even if they have data in them). Essential for development iteration.

In **staging and prod**, set to `false`. This prevents a `terraform destroy` from deleting buckets that have data. Terraform will refuse to delete a non-empty bucket, protecting production data.

---

## Module Outputs

| Output | What it contains | Used By |
|---|---|---|
| `bronze_bucket_name` | Full S3 bucket name | `iam-metadata`, `ingestion`, `processing` |
| `silver_bucket_name` | Full S3 bucket name | `iam-metadata`, `processing`, `serving` |
| `gold_bucket_name` | Full S3 bucket name | `iam-metadata`, `serving` |
| `quarantine_bucket_name` | Full S3 bucket name | `iam-metadata` |
| `athena_results_bucket` | Full S3 bucket name | `processing` |

**Why outputs matter:** No other module should hardcode a bucket name. Instead, they reference these outputs:

```hcl
# In the environment's main.tf:
module "iam_metadata" {
  source             = "../../modules/iam-metadata"
  bronze_bucket_name = module.data_lake.bronze_bucket_name  # ← from this module's output
  silver_bucket_name = module.data_lake.silver_bucket_name
  ...
}
```

This creates an explicit dependency graph. Terraform knows it must create the data-lake buckets before creating the IAM roles that reference them.

---

## How to Deploy This Module

This module is deployed as part of an environment (not standalone). The environment's `main.tf` calls it.

### Deploy via Makefile (recommended)

From inside `terraform-platform-infra-live/`:

```bash
# First time only — initialize Terraform
make init dev

# Preview what will be created
make plan dev

# Create the infrastructure
make apply dev
```

### Deploy manually

```bash
aws sso login --profile dev-admin

cd terraform-platform-infra-live/environments/dev

terraform init    # Download providers, register modules
terraform plan    # Preview changes
terraform apply   # Create resources
```

---

## Validation Checklist

After running `terraform apply`, verify in the AWS Console:

**S3 Console → Buckets:**
- [ ] `edp-dev-<account_id>-bronze` exists
- [ ] `edp-dev-<account_id>-silver` exists
- [ ] `edp-dev-<account_id>-gold` exists
- [ ] `edp-dev-<account_id>-quarantine` exists
- [ ] `edp-dev-<account_id>-athena-results` exists

**For each bucket, check:**
- [ ] Properties → Encryption: Server-side encryption enabled (AES-256)
- [ ] Properties → Bucket Versioning: Enabled
- [ ] Permissions → Block public access: All four blocks are ON
- [ ] Tags: `Environment`, `ManagedBy`, `Project`, `AccountID` are set

---

## Environment Differences

| Setting | dev | staging | prod |
|---|---|---|---|
| `force_destroy` | `true` | `false` | `false` |
| Bucket suffix | `-dev-` | `-staging-` | `-prod-` |
| Tags | `Environment = dev` | `Environment = staging` | `Environment = prod` |

Everything else is identical. This is the power of modules — one codebase, three environments.

---

## What Comes Next

After the data lake is deployed:

1. **`iam-metadata` module** — Creates IAM roles that grant Glue, MWAA, Redshift, and DMS access to these specific buckets
2. **`ingestion` module** — Sets up DMS to write CDC data into the Bronze bucket
3. **`processing` module** — Sets up Glue and Athena to read Bronze and write Silver/Gold

---

## Files in This Module

| File | Purpose |
|---|---|
| `main.tf` | All S3 bucket resources, encryption, versioning, and public access blocks |
| `variables.tf` | Input variable declarations (`environment`, `force_destroy`, `name_prefix`) |
| `outputs.tf` | Exports all five bucket names for use by other modules |
