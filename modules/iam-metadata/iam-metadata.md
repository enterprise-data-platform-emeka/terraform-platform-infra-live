# Module: iam-metadata

**Location:** `terraform-platform-infra-live/modules/iam-metadata/`

**Depends on:** `data-lake` module (needs the S3 bucket names)

---

## What this module does

This module creates three things that every other service in the platform needs before it can do anything:

1. **An encryption key** — A KMS (Key Management Service) key that locks data so only authorised services can read it
2. **IAM (Identity and Access Management) roles** — Permission cards that tell AWS which services are allowed to do what
3. **A metadata catalog** — Three Glue (AWS Glue is a managed data integration service) databases that store the structure of my data so query tools know what columns and data types exist in each S3 (Simple Storage Service) bucket

Think of it this way: before any workers enter a secure building, they need a photo ID badge (the IAM role), a keycard for the doors they are allowed through (the permissions), and access to the building's filing system so they know where everything is (the Glue catalog). This module creates all of that.

---

## Why IAM roles instead of IAM users

IAM users have permanent credentials called access keys. If those keys are leaked or stolen, they give someone permanent access until the keys are manually revoked.

IAM roles work differently. Instead of permanent keys, a role issues short-lived temporary credentials that expire automatically after a few hours. AWS services assume a role when they need to do something, get temporary credentials, do their work, and the credentials expire. There are no long-lived secrets to leak.

I create one dedicated role for each service. Each role has exactly the permissions that service needs and nothing more. This approach is called the principle of least privilege. It limits the damage if any single service is ever compromised.

| Service | Role name | What it is allowed to do |
|---|---|---|
| AWS Glue | `edp-{env}-glue-role` | Read and write Bronze, Silver, Gold, and Quarantine S3 buckets; use the KMS key; manage the Glue catalog |
| Amazon MWAA (Managed Workflows for Apache Airflow) | `edp-{env}-mwaa-role` | Read the DAGs (Directed Acyclic Graphs, which are Airflow workflow files) bucket; write logs to CloudWatch; trigger Glue jobs; use the KMS key |
| Amazon Redshift Serverless | `edp-{env}-redshift-role` | Read Silver and Gold S3 buckets via Redshift Spectrum; use the KMS key; read the Glue catalog |
| AWS DMS (Database Migration Service) | `edp-{env}-dms-s3-role` | Write Parquet files to the Bronze S3 bucket; use the KMS key to encrypt those files |
| AWS DMS (network access) | `dms-vpc-role` | Fixed name required by AWS. Allows DMS to create network interfaces inside the VPC (Virtual Private Cloud) |
| AWS DMS (logging) | `dms-cloudwatch-logs-role` | Fixed name required by AWS. Allows DMS to write logs to CloudWatch |

---

## Resources created

### 1. KMS key

KMS (Key Management Service) is AWS's service for creating and managing encryption keys. An encryption key is like a very complex password that is used to scramble data. Only services that are explicitly granted access to the key can unscramble it.

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

**`deletion_window_in_days = 30`:** When I delete a KMS key, AWS does not destroy it immediately. It waits 30 days. During this window, I can cancel the deletion if it was a mistake. After 30 days, the key is gone permanently and anything encrypted with it becomes unreadable. This safety window protects me from accidental key deletion.

**`enable_key_rotation = true`:** AWS automatically replaces the key material (the actual cryptographic secret inside the key) once every year. This is a security best practice. If old key material were ever exposed, it becomes useless after rotation. Data stays readable because AWS keeps track of which key material encrypted which data and uses the right one for decryption.

**`aws_kms_alias`:** KMS keys have IDs that look like `arn:aws:kms:eu-central-1:123456789012:key/abc-123-xyz`. An alias gives the key a human-readable name, like `alias/edp-dev-platform`, so I can identify it in the AWS console without memorising a random string.

This single KMS key is shared across all services: DMS (Database Migration Service) uses it to encrypt RDS (Relational Database Service) storage, Glue uses it to encrypt job output, MWAA uses it to encrypt environment variables, and Redshift uses it to encrypt the data warehouse.

---

### 2. Glue Data Catalog databases

```hcl
resource "aws_glue_catalog_database" "bronze" {
  name        = "${var.name_prefix}_${var.environment}_bronze"
  description = "Bronze layer - raw CDC-ingested data"
}

resource "aws_glue_catalog_database" "silver" { ... }
resource "aws_glue_catalog_database" "gold"   { ... }
```

The AWS Glue Data Catalog is a metadata repository. Metadata means "data about data." The catalog stores things like: "The Bronze S3 bucket has a table called `orders`. It has columns `order_id` (string), `amount` (decimal), and `created_at` (timestamp). The files are in Parquet format."

Without these catalog entries, Amazon Athena (AWS's serverless SQL query engine) and Redshift Spectrum do not know how to read my S3 files. They would just see a folder full of binary files with no idea what the columns are or what format the data is in.

I create one database per medallion layer: Bronze, Silver, and Gold. Later, Glue crawlers (automated schema discovery tools) or manual table definitions will add individual tables to these databases as data lands in each bucket.

**Why underscores in the name?** The Glue catalog database name uses underscores (`edp_dev_bronze`) rather than hyphens (`edp-dev-bronze`) because the Glue catalog follows SQL (Structured Query Language) naming conventions and SQL does not allow hyphens in database names.

---

### 3. IAM role for Glue

```hcl
resource "aws_iam_role" "glue" {
  name               = "${var.name_prefix}-${var.environment}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}
```

**The trust policy (who can assume this role):**

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

STS (Security Token Service) is the AWS service that issues temporary credentials. The `sts:AssumeRole` action is what a service calls when it wants to use a role. This trust policy says: "Only the AWS Glue service (`glue.amazonaws.com`) is allowed to call `sts:AssumeRole` on this role." No human, no other service, nothing else can use this role.

**Two policies are attached to this role:**

The first is `AWSGlueServiceRole`, an AWS-managed policy. AWS maintains this policy and it gives Glue the general operational permissions it needs: create CloudWatch log groups, describe VPC (Virtual Private Cloud) resources, and access Glue's own control plane.

The second is a custom inline policy I write that grants data-specific permissions: read and write access to the Bronze, Silver, Gold, and Quarantine S3 buckets; the ability to use the KMS key to encrypt and decrypt data; and Glue catalog operations like creating tables and adding partitions.

I keep these two policies separate because the AWS-managed policy covers Glue infrastructure needs, and the custom policy covers data access. This separation makes it clear which permissions are operational and which are data-related.

---

### 4. IAM role for MWAA

```hcl
resource "aws_iam_role" "mwaa" {
  name               = "${var.name_prefix}-${var.environment}-mwaa-role"
  assume_role_policy = data.aws_iam_policy_document.mwaa_assume_role.json
}
```

MWAA (Amazon Managed Workflows for Apache Airflow) is the orchestration service that runs Airflow, the workflow scheduling tool. Airflow is responsible for triggering Glue jobs, monitoring them, and triggering the next step in the pipeline when each job completes.

The trust policy for this role allows both `airflow.amazonaws.com` and `airflow-env.amazonaws.com` to assume it. MWAA runs two internal sub-services: the Airflow control plane and the environment runtime. Both need to use this role.

| Permission | Why MWAA needs it |
|---|---|
| Read the DAGs S3 bucket | Airflow reads its workflow Python files from S3 |
| Write to CloudWatch logs | Airflow writes scheduler, worker, and webserver logs here |
| Publish CloudWatch metrics | Airflow publishes health and performance metrics |
| Access SQS (Simple Queue Service) on Celery queues | MWAA uses Apache Celery internally to distribute tasks to workers |
| Use the KMS key | Encrypts Airflow connection strings, environment variables, and decrypts SSM SecureString parameters |
| Call Glue StartJobRun and GetJobRun | Airflow DAGs trigger Glue jobs and wait for them to finish |
| Read SSM parameters at `/edp/{env}/*` | Airflow DAGs fetch the RDS and Redshift passwords from SSM Parameter Store at runtime. No passwords are stored in Airflow connections or environment variables |

The DAGs bucket name is constructed using the same naming formula as the bucket the `orchestration` module will create:

```hcl
"arn:aws:s3:::${var.name_prefix}-${var.environment}-${data.aws_caller_identity.current.account_id}-mwaa-dags"
```

`aws_caller_identity` is a Terraform data source that fetches the current AWS account ID. ARN (Amazon Resource Name) is the unique identifier for any AWS resource. By referencing the account ID in the ARN, I can construct the exact bucket name without creating a circular dependency between modules.

---

### 5. IAM role for Redshift Serverless

```hcl
resource "aws_iam_role" "redshift" {
  name               = "${var.name_prefix}-${var.environment}-redshift-role"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume_role.json
}
```

The trust policy allows both `redshift.amazonaws.com` and `redshift-serverless.amazonaws.com` to assume this role. Redshift Serverless is the version of Redshift that does not require managing a cluster.

| Permission | Why Redshift needs it |
|---|---|
| S3 GetObject and ListBucket on Silver and Gold | Redshift Spectrum reads external tables directly from S3 |
| KMS Decrypt and GenerateDataKey | Decrypts files that Glue encrypted when writing to Silver and Gold |
| Glue GetDatabase, GetTable, GetPartitions | Spectrum queries the Glue catalog to learn the table structure |

Redshift Spectrum is a feature that lets Redshift run SQL queries against data that lives in S3 rather than inside Redshift's own storage. A query like `SELECT * FROM spectrum.orders LIMIT 100` reads directly from the Gold S3 bucket by looking up the table definition in the Glue catalog. This means I do not need to copy data into Redshift before analysts can query it.

---

### 6. IAM roles for DMS

DMS requires three separate IAM roles, two of which have names that are fixed by AWS and cannot be changed.

**`dms-vpc-role` (the name is required by AWS DMS):**

```hcl
resource "aws_iam_role" "dms_vpc" {
  name = "dms-vpc-role"
  ...
}
resource "aws_iam_role_policy_attachment" "dms_vpc" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}
```

When DMS creates a replication instance inside my VPC, it needs to create ENIs (Elastic Network Interfaces). An ENI is a virtual network card: it is the thing that gives a service an IP address inside the VPC. DMS uses this role to get permission to create those network cards. AWS looks for exactly the name `dms-vpc-role` in my account. If the role has any other name, DMS cannot find it and the replication instance creation fails.

**`dms-cloudwatch-logs-role` (the name is required by AWS DMS):**

This role allows DMS to write replication logs to CloudWatch. Again, the name is hardcoded into the DMS service.

**Important note about these two fixed-name roles:** If these roles already exist in my AWS account from a previous Terraform deployment or from manually setting up DMS, Terraform will fail when trying to create them again. AWS will return an error saying the roles already exist. The fix is to import them into Terraform state:

```bash
terraform import module.iam_metadata.aws_iam_role.dms_vpc dms-vpc-role
terraform import module.iam_metadata.aws_iam_role.dms_cloudwatch dms-cloudwatch-logs-role
```

`terraform import` tells Terraform: "This resource already exists in AWS. Start tracking it without trying to create it." After importing, Terraform manages the roles normally.

**`{name_prefix}-{env}-dms-s3-role` (custom name):**

This is the role the DMS replication task uses when writing CDC (Change Data Capture) data to the Bronze S3 bucket. It grants DMS permission to write Parquet files to the Bronze bucket and to use the KMS key to encrypt those files. CDC is the process of capturing every individual database change (insert, update, delete) and streaming it to the data lake.

---

## Module inputs (variables)

| Variable | Type | Description |
|---|---|---|
| `environment` | string | Environment name: `dev`, `staging`, or `prod` |
| `name_prefix` | string | Short prefix for all resource names, for example `edp` |
| `bronze_bucket_name` | string | Bronze bucket name from the `data-lake` module output |
| `silver_bucket_name` | string | Silver bucket name from the `data-lake` module output |
| `gold_bucket_name` | string | Gold bucket name from the `data-lake` module output |
| `quarantine_bucket_name` | string | Quarantine bucket name from the `data-lake` module output |

---

## Module outputs

| Output | Used by |
|---|---|
| `kms_key_arn` | All modules that encrypt data: ingestion, processing, serving, orchestration |
| `kms_key_id` | Available if any module needs to reference the key by ID |
| `glue_role_arn` | `processing` module assigns this role to the Glue security configuration |
| `mwaa_role_arn` | `orchestration` module assigns this role to the MWAA environment |
| `redshift_role_arn` | `serving` module assigns this role to the Redshift namespace |
| `dms_s3_role_arn` | `ingestion` module assigns this role to the DMS S3 target endpoint |
| `glue_catalog_database_bronze` | Referenced by Glue crawlers and Athena queries targeting Bronze data |
| `glue_catalog_database_silver` | Referenced by Glue crawlers and Athena queries targeting Silver data |
| `glue_catalog_database_gold` | Referenced by dbt (data build tool) and Athena queries targeting Gold data |

---

## How to deploy

This module is deployed as part of an environment, not on its own.

```bash
aws sso login --profile dev-admin
```

SSO (Single Sign-On) is AWS's identity service that issues temporary login credentials. I run this before any Terraform command to refresh those credentials.

```bash
# From inside terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

The environment's `main.tf` calls this module like this:

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

The bucket names come from `module.data_lake` outputs. Terraform sees this reference and automatically creates the data lake buckets before creating the IAM roles. I do not need to manually enforce the order.

---

## Validation checklist

After `terraform apply`, I check the following in the AWS console:

**KMS console:**
- [ ] Key with alias `alias/edp-dev-platform` exists
- [ ] Key state: Enabled
- [ ] Key rotation: Enabled

**IAM (Identity and Access Management) console, Roles section:**
- [ ] `edp-dev-glue-role` exists and is trusted by `glue.amazonaws.com`
- [ ] `edp-dev-mwaa-role` exists and is trusted by `airflow.amazonaws.com`
- [ ] `edp-dev-redshift-role` exists and is trusted by `redshift-serverless.amazonaws.com`
- [ ] `edp-dev-dms-s3-role` exists and is trusted by `dms.amazonaws.com`
- [ ] `dms-vpc-role` exists
- [ ] `dms-cloudwatch-logs-role` exists

**Glue console, Databases section:**
- [ ] `edp_dev_bronze` database exists
- [ ] `edp_dev_silver` database exists
- [ ] `edp_dev_gold` database exists

---

## What comes next

After this module is deployed:

1. **`ingestion` module** — Creates the RDS (Relational Database Service) PostgreSQL source database and the DMS replication instance, using the KMS key and DMS role ARNs (Amazon Resource Names) from this module
2. **`processing` module** — Creates the Glue security configuration and Athena workgroup, using the Glue role ARN from this module
3. **`serving` module** — Creates the Redshift Serverless namespace and workgroup, using the Redshift role ARN and KMS key ARN from this module
4. **`orchestration` module** — Creates the MWAA environment, using the MWAA role ARN and KMS key ARN from this module

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | KMS key and alias, Glue catalog databases, all IAM roles and attached policies |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Exports the KMS key ARN, all role ARNs, and Glue database names |
