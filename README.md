# terraform-platform-infra-live

This repository is part of the [Enterprise Data Platform](https://github.com/enterprise-data-platform-emeka/platform-docs). For the full project overview, architecture diagram, and build order, start there.

---

This repository contains all the AWS (Amazon Web Services) infrastructure for the Enterprise Data Platform, written as Terraform code. If the `terraform-bootstrap` repository creates the filing cabinet (remote state storage), this repository builds everything inside it: the private network, the data storage buckets, the encryption keys, the permissions, the databases, the data processing environment, the data warehouse, and the pipeline orchestration system.

Every AWS resource this platform needs is defined here. Nothing is created manually in the AWS console.

---

## What lives in this repository

The infrastructure is organized as modules. Each module has one job and creates a specific group of related resources. The modules are called from environment folders (dev, staging, prod), where environment-specific values are passed in.

```
terraform-platform-infra-live/
│
├── Makefile                          Shortcuts for common Terraform commands
│
├── modules/
│   ├── networking/                   VPC, subnets, route tables, S3 endpoint
│   ├── data-lake/                    Five S3 data lake buckets
│   ├── iam-metadata/                 KMS key, IAM roles, Glue Catalog databases
│   ├── ingestion/                    RDS PostgreSQL database and DMS replication
│   ├── processing/                   Glue security config and Athena workgroup
│   ├── serving/                      Redshift Serverless namespace and workgroup
│   └── orchestration/                MWAA environment, ECS cluster, CloudWatch logs
│
└── environments/
    ├── dev/
    │   ├── main.tf                   Calls all modules with dev-specific values
    │   ├── variables.tf              Input variable definitions for dev
    │   ├── providers.tf              AWS provider configuration
    │   ├── versions.tf               Terraform and provider version locks
    │   └── backend.tf                Remote state backend (S3 + DynamoDB)
    │
    ├── staging/                      Same structure as dev
    └── prod/                         Same structure as dev
```

---

## The seven modules and what they create

| Module | Resources created |
|---|---|
| networking | VPC (Virtual Private Cloud), public subnet, two private subnets, Internet Gateway, route tables, S3 VPC Endpoint |
| data-lake | Five S3 (Simple Storage Service) buckets: Bronze, Silver, Gold, Quarantine, Athena results |
| iam-metadata | KMS (Key Management Service) encryption key, IAM (Identity and Access Management) roles for Glue/MWAA/Redshift/DMS, three Glue Catalog databases |
| ingestion | RDS (Relational Database Service) PostgreSQL database, DMS (Database Migration Service) replication instance, DMS source and target endpoints, DMS replication task |
| processing | Glue security configuration, Glue VPC connection, Athena workgroup |
| serving | Redshift Serverless namespace and workgroup |
| orchestration | MWAA (Amazon Managed Workflows for Apache Airflow) environment, ECS (Elastic Container Service) cluster, DAG bucket, CloudWatch log groups |

---

## Module dependency order

The modules depend on each other in a strict order. I cannot deploy a module until everything it depends on already exists.

```
networking
  └── data-lake
        └── iam-metadata
              ├── ingestion
              ├── processing
              ├── serving
              └── orchestration
```

**Why this order:**

- `networking` has no dependencies. It creates the VPC and subnets. Everything else runs inside this network.
- `data-lake` creates the S3 buckets. It needs networking to exist (for the S3 VPC endpoint association) and its bucket names are passed as inputs to modules below.
- `iam-metadata` creates IAM roles using the bucket names from `data-lake`. The roles grant Glue, DMS, MWAA, and Redshift access to specific buckets. It also creates the KMS encryption key used by everything below.
- `ingestion`, `processing`, `serving`, and `orchestration` all need the VPC ID, subnet IDs, KMS key ARN, and IAM role ARNs from the modules above. They can be applied in any order relative to each other, but only after `iam-metadata` exists.

---

## Using the Makefile

I use a Makefile to avoid typing long Terraform commands with directory paths every time.

| Command | What it runs |
|---|---|
| `make init dev` | `cd environments/dev && terraform init` |
| `make plan dev` | `cd environments/dev && terraform plan` |
| `make apply dev` | `cd environments/dev && terraform apply` |
| `make destroy dev` | `cd environments/dev && terraform destroy` |

Replace `dev` with `staging` or `prod` for other environments. Always log in to AWS SSO (Single Sign-On) before running any of these.

```bash
aws sso login --profile dev-admin
make init dev
make plan dev
make apply dev
```

---

## Sensitive variables

Two variables have no defaults and must be provided at apply time. Never put these in a `.tf` file or commit them to Git.

| Variable | What it is |
|---|---|
| `db_password` | The master password for the RDS PostgreSQL database |
| `redshift_admin_password` | The admin password for the Redshift Serverless namespace |

**Recommended — environment variables:**

```bash
export TF_VAR_db_password="YourSecurePassword123!"
export TF_VAR_redshift_admin_password="AnotherSecurePassword456!"
make apply dev
```

Terraform reads any `TF_VAR_*` environment variable and maps it to the matching variable.

**After `make apply dev` completes**, both passwords are automatically stored in AWS SSM (Systems Manager) Parameter Store as encrypted `SecureString` parameters:

| SSM path | What it stores |
|---|---|
| `/edp/dev/rds/db_password` | RDS PostgreSQL master password |
| `/edp/dev/redshift/admin_password` | Redshift Serverless admin password |

From that point on, no tool (simulator, Airflow DAG, script) ever needs a password file. They fetch the value from SSM at runtime using the `dev-admin` AWS profile.

**Alternative — tfvars file (excluded from Git):**

```bash
# Create environments/dev/secret.tfvars
# Add this file to .gitignore

db_password             = "YourSecurePassword123!"
redshift_admin_password = "AnotherSecurePassword456!"

# Apply with:
terraform apply -var-file="secret.tfvars"
```

---

## Important deployment notes

### 1. Apply iam-metadata before ingestion

The DMS (Database Migration Service) service requires two IAM roles with fixed names to exist before I can create a replication instance:

- `dms-vpc-role` - allows DMS to create network interfaces in the VPC
- `dms-cloudwatch-logs-role` - allows DMS to write logs to CloudWatch

These roles are created by the `iam-metadata` module. If I try to apply `ingestion` before `iam-metadata`, the DMS replication instance creation will fail.

### 2. The two fixed DMS role names

AWS DMS (Database Migration Service) looks for exactly these role names in every account. The names cannot be changed. If these roles already exist in the AWS account from a previous deployment, Terraform will fail when trying to create them again because they already exist.

In that case, import them into Terraform state:

```bash
terraform import module.iam_metadata.aws_iam_role.dms_vpc dms-vpc-role
terraform import module.iam_metadata.aws_iam_role.dms_cloudwatch dms-cloudwatch-logs-role
```

After importing, Terraform knows these resources already exist and will manage them without trying to recreate them.

### 3. RDS reboot after first apply

The RDS (Relational Database Service) PostgreSQL instance needs logical replication mode enabled for CDC (Change Data Capture) to work. This is set in the parameter group, but the parameter requires a database restart to take effect.

After the first `terraform apply`, reboot the RDS instance:

```bash
aws rds reboot-db-instance \
  --db-instance-identifier edp-dev-source-db \
  --profile dev-admin
```

Wait for the instance to return to `available` status before proceeding.

### 4. Start the DMS task manually

After the infrastructure is applied and the RDS instance has been rebooted, the DMS replication task needs to be started manually. Terraform creates the task but does not start it.

```bash
aws dms start-replication-task \
  --replication-task-arn <task_arn_from_terraform_output> \
  --start-replication-task-type start-replication \
  --profile dev-admin
```

The task ARN is in the Terraform output after `make apply dev`.

---

## Inspecting created resources in the AWS console

After `make apply dev` completes, I can verify what Terraform built in two ways. Both require being logged in to the correct AWS account and being in the **eu-central-1 (Frankfurt)** region. The region selector is in the top-right corner of every AWS console page.

---

### Method 1: Tag Editor (fastest — everything in one view)

Tag Editor searches across all AWS resource types and returns every resource that matches a given tag. Because Terraform tags every resource with `Project = EnterpriseDataPlatform`, a single search shows the full inventory without clicking through multiple service consoles.

**Steps:**

1. Open the AWS console and go to **Resource Groups and Tag Editor**. I can find it by typing "Tag Editor" in the top search bar.
2. Click **Tag Editor** in the left sidebar.
3. Set the search fields:
   - **Regions:** `eu-central-1`
   - **Resource types:** leave as "All resource types"
   - **Tags:** Key = `Project`, Value = `EnterpriseDataPlatform`
4. Click **Search resources**.

Every resource Terraform created appears in the results list with its type, name, region, and ARN (Amazon Resource Name). I can sort by resource type to group related resources together.

**When to use this method:** when I want to confirm everything was created and nothing is missing, or when I want a quick count of total resources before running `make destroy dev`.

---

### Method 2: Service by service (most detail)

This method goes directly to each service's console for the richest view of each resource. It takes longer but shows configuration details, connection status, and metrics that Tag Editor does not.

**Always check that the region is set to eu-central-1 before navigating to any service.**

| Service | Console path | What to look for |
|---|---|---|
| VPC (Virtual Private Cloud) | VPC → Your VPCs | `edp-dev-vpc`, 3 subnets, S3 VPC Endpoint on private route table |
| S3 (Simple Storage Service) | S3 → Buckets | 5 buckets with `edp-dev-` prefix, encryption and versioning enabled on each |
| RDS (Relational Database Service) | RDS → Databases | `edp-dev-source-db` showing status `available` |
| DMS (Database Migration Service) | DMS → Replication instances / Tasks | `edp-dev-dms-ri` showing `available`, `edp-dev-cdc-task` visible |
| EC2 (Elastic Compute Cloud) | EC2 → Instances | `edp-dev-bastion` showing `running` |
| KMS (Key Management Service) | KMS → Customer managed keys | Key with alias `alias/edp-dev-platform` |
| IAM (Identity and Access Management) | IAM → Roles, filter by `edp` | All service roles for Glue, MWAA, Redshift, DMS |
| Glue | Glue → Databases | `edp_dev_bronze`, `edp_dev_silver`, `edp_dev_gold` |
| Athena | Athena → Workgroups | `edp-dev-workgroup` showing `ENABLED` |
| Redshift Serverless | Redshift Serverless → Workgroups | `edp-dev-workgroup` and `edp-dev-namespace` |
| SSM (Systems Manager) | Systems Manager → Parameter Store | `/edp/dev/rds/db_password` and `/edp/dev/redshift/admin_password` as `SecureString` |

**When to use this method:** when verifying a specific resource in detail, troubleshooting a connection issue, or checking DMS task status and replication lag.

---

## Full validation checklist

After `make apply dev` completes successfully, verify the following in the AWS console:

**VPC (Virtual Private Cloud) Console:**
- VPC `edp-dev-vpc` exists with CIDR (Classless Inter-Domain Routing) `10.10.0.0/16`
- Three subnets exist: one public, two private (in different AZs - Availability Zones)
- Private route table has no internet route
- S3 VPC Endpoint is attached to the private route table

**S3 (Simple Storage Service) Console:**
- Five buckets exist with the correct naming pattern
- All buckets: encryption enabled, versioning enabled, public access blocked

**KMS (Key Management Service) Console:**
- Key with alias `alias/edp-dev-platform` exists
- Key rotation is enabled

**IAM (Identity and Access Management) Console:**
- `edp-dev-glue-role` exists
- `edp-dev-mwaa-role` exists
- `edp-dev-redshift-role` exists
- `edp-dev-dms-s3-role` exists
- `dms-vpc-role` exists
- `dms-cloudwatch-logs-role` exists

**Glue Console:**
- Three databases: `edp_dev_bronze`, `edp_dev_silver`, `edp_dev_gold`

**RDS (Relational Database Service) Console:**
- Instance `edp-dev-source-db` is in `available` state
- Storage encrypted: Yes
- Parameter group: `edp-dev-postgres16`

**DMS (Database Migration Service) Console:**
- Replication instance `edp-dev-dms-ri` is `available`
- Source endpoint test connection: successful
- Target endpoint test connection: successful
- Replication task is visible (not yet started)

**SSM (Systems Manager) Parameter Store:**
- Parameter `/edp/dev/rds/db_password` exists as a `SecureString`
- Parameter `/edp/dev/redshift/admin_password` exists as a `SecureString`

**Redshift Console:**
- Namespace `edp-dev-namespace` exists
- Workgroup `edp-dev-workgroup` exists

**MWAA (Amazon Managed Workflows for Apache Airflow) Console:**
- Environment `edp-dev-mwaa` is in `Available` state

---

## Environments

Each environment folder calls all the modules with environment-specific values. The code is identical across dev, staging, and prod. Only the variable values change.

| Environment | AWS profile | VPC CIDR | Active development |
|---|---|---|---|
| dev | dev-admin | 10.10.0.0/16 | Yes - this is where I build |
| staging | staging-admin | 10.20.0.0/16 | Temporary - spin up to validate, then destroy |
| prod | prod-admin | 10.30.0.0/16 | Temporary - spin up to confirm, then destroy |

I keep dev running when I am actively building. I destroy it between sessions to save costs. MWAA costs about $0.49 per hour and RDS costs about $0.013 per hour, so leaving them running overnight adds up quickly.

---

## CI/CD

CI and deploy only trigger when Terraform source files change (`environments/**` or `modules/**`). README updates, Makefile changes, and module documentation never trigger a workflow run.

### On every pull request to main

Three jobs run in order:

**Validate (parallel across all three environments):**

Runs `terraform fmt -check` and `terraform validate` against dev, staging, and prod simultaneously using `-backend=false` (no AWS credentials needed). This catches HCL syntax errors and schema problems before any AWS calls happen.

**Security scan:**

tfsec scans all Terraform modules for HIGH and CRITICAL severity findings. MEDIUM and LOW findings are reviewed and suppressed with inline `tfsec:ignore` annotations where the pattern is intentional.

**Plan (after validate and security pass):**

Runs `terraform plan` against the dev environment using OIDC (OpenID Connect) authentication. The plan output is posted as a comment on the pull request so reviewers see exactly what will change before approving the merge. The comment is updated on each new push to the PR so it always shows the latest plan.

### On merge to main

The deploy workflow triggers automatically and runs `terraform plan` then `terraform apply` against dev. The plan output is written to the GitHub Actions job summary for audit trail. Authentication uses OIDC, no long-lived AWS credentials are stored anywhere.

Before the plan runs, `requirements.txt` and `plugins.zip` are downloaded from the MWAA S3 (Simple Storage Service) bucket. The orchestration module calls `filemd5()` on these files at plan time. Downloading them from S3 ensures the MD5 hash matches what is already in Terraform state, so Terraform sees no change to the MWAA environment and does not trigger a 35-minute MWAA environment update on every infrastructure deploy.

### Promotion to staging and prod

Trigger the Deploy workflow manually from GitHub Actions and choose the target environment. GitHub Environment protection rules require reviewer approval for staging and prod before the job runs.

---

## Module READMEs

Each module has its own documentation file with detailed explanations of every resource it creates:

- `modules/networking/networking.md`
- `modules/data-lake/data-lake.md`
- `modules/iam-metadata/iam-metadata.md`
- `modules/ingestion/ingestion.md`
- `modules/serving/serving.md`
- `modules/processing/` (coming soon)
- `modules/orchestration/` (coming soon)
