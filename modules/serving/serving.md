# Module: serving

**Location:** `terraform-platform-infra-live/modules/serving/`

**Depends on:** `networking` (vpc_id, vpc_cidr, private_subnet_ids), `iam-metadata` (kms_key_arn, redshift_role_arn)

---

## What this module does

This module creates the data warehouse layer of the platform: Amazon Redshift Serverless. Redshift is where analysts and BI (Business Intelligence) tools connect to run SQL (Structured Query Language) queries against the Gold layer data.

Redshift Serverless has no cluster to manage. I do not pick a node type or configure a cluster size. Instead, I set a base compute capacity and Redshift scales up or down automatically depending on query demand. When no queries are running, I pay nothing for compute.

This module creates two resources:

1. **A namespace** — the storage container. It holds the database, admin credentials, and the IAM (Identity and Access Management) role that Redshift uses to read from S3 (Simple Storage Service) and the Glue catalog.
2. **A workgroup** — the compute container. It lives inside the VPC (Virtual Private Cloud) private subnets and is where SQL connections are made.

---

## How Redshift fits in the platform

```
Gold S3 Bucket                Glue Data Catalog
(aggregated data)             (table schemas)
        │                            │
        └──────────┬─────────────────┘
                   │  Redshift Spectrum reads both
                   ▼
        ┌──────────────────────┐
        │  Redshift Serverless │
        │  Workgroup           │
        └──────────┬───────────┘
                   │  SQL
        ┌──────────▼───────────┐
        │  BI Tools / Analysts │
        │  (Tableau, Power BI, │
        │   psql, dbt)         │
        └──────────────────────┘
```

Redshift Spectrum is the feature that lets Redshift query data that lives in S3 directly, without first loading it into Redshift's internal storage. A query like `SELECT * FROM spectrum.daily_revenue LIMIT 100` reads directly from the Gold S3 bucket by looking up the table definition in the Glue catalog.

This means analysts can query the Gold layer through a familiar SQL interface without any data movement step.

---

## Resources created

### 1. Security group for Redshift

```hcl
resource "aws_security_group" "redshift" {
  name   = "${var.name_prefix}-${var.environment}-redshift-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}
```

Port 5439 is the port Redshift listens on. The ingress rule allows connections from within the VPC CIDR (Classless Inter-Domain Routing, the IP address range for the entire VPC). This means only resources inside the VPC can connect to Redshift: Airflow DAGs (Directed Acyclic Graphs, the Airflow workflow files), dbt (data build tool) running from a bastion host, or any other internal service.

No connection from the public internet is possible. `publicly_accessible = false` on the workgroup also prevents Redshift from being assigned a public IP address.

---

### 2. Redshift Serverless namespace

```hcl
resource "aws_redshiftserverless_namespace" "this" {
  namespace_name      = "${var.name_prefix}-${var.environment}-namespace"
  admin_username      = var.redshift_admin_username
  admin_user_password = var.redshift_admin_password
  db_name             = var.redshift_db_name

  iam_roles  = [var.redshift_role_arn]
  kms_key_id = var.kms_key_arn

  log_exports = ["userlog", "connectionlog", "useractivitylog"]
}
```

A namespace is the administrative boundary for a Redshift Serverless deployment. It is an account-level resource (not deployed inside a specific VPC) and it holds:

**`admin_username` and `admin_user_password`:** The master credentials for the database. I use these only for initial setup and to create other database users. These are sensitive variables that must never be committed to Git.

**`db_name`:** The name of the default database created inside the namespace. I set this to `edp` (Enterprise Data Platform). Analysts connect to this database.

**`iam_roles`:** The IAM role the namespace assumes when it needs to access external resources. I attach the `redshift_role_arn` created by the `iam-metadata` module, which grants Redshift permission to read from S3 (Silver and Gold buckets) and look up table schemas in the Glue catalog.

**`kms_key_id`:** All data stored in the namespace is encrypted using the platform KMS key.

**`log_exports`:** Three log types are sent to CloudWatch (Amazon's monitoring and logging service):
- `userlog`: Records user login and logout events
- `connectionlog`: Records each database connection attempt (source IP, username, outcome)
- `useractivitylog`: Records every SQL query run against the database

These logs are important for security auditing and for debugging query performance problems.

---

### 3. Redshift Serverless workgroup

```hcl
resource "aws_redshiftserverless_workgroup" "this" {
  namespace_name = aws_redshiftserverless_namespace.this.namespace_name
  workgroup_name = "${var.name_prefix}-${var.environment}-workgroup"

  base_capacity       = var.base_capacity_rpus
  publicly_accessible = false

  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.redshift.id]
}
```

A workgroup is the compute layer. It is what actually processes queries. While the namespace holds data and credentials, the workgroup is what you connect to when running SQL.

**`base_capacity`:** Measured in RPUs (Redshift Processing Units). One RPU is a unit of compute that Redshift uses internally to measure query processing capacity. The minimum is 8 RPUs. For development, 8 RPUs is enough for testing and moderate query workloads. Redshift Serverless scales up automatically if a complex query requires more compute and scales back down after.

**`publicly_accessible = false`:** The workgroup does not get a public IP address or a public DNS (Domain Name System) hostname. It is only reachable from inside the VPC.

**`subnet_ids`:** I pass both private subnets. Redshift Serverless requires at least two subnets in different AZs (Availability Zones, which are independent data centres within the same AWS region) for high availability. Even in dev, this requirement exists.

**`depends_on`:** The workgroup must wait for the namespace to be fully created before it can reference it. Terraform handles this automatically through the resource reference, but the explicit `depends_on` makes the ordering unambiguous.

---

### 4. SSM parameter for the Redshift password

```hcl
resource "aws_ssm_parameter" "redshift_admin_password" {
  name        = "/edp/${var.environment}/redshift/admin_password"
  description = "Redshift Serverless admin password — ${var.environment}"
  type        = "SecureString"
  value       = var.redshift_admin_password
  key_id      = var.kms_key_arn
}
```

After Terraform applies, the Redshift admin password is automatically stored in SSM (Systems Manager) Parameter Store at `/edp/{environment}/redshift/admin_password` as a `SecureString` encrypted with the platform KMS key. Any tool that needs to connect to Redshift — an Airflow DAG, a dbt profile script, a maintenance utility — can fetch it at runtime without any password file on disk:

```bash
aws ssm get-parameter \
  --name /edp/dev/redshift/admin_password \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --profile dev-admin
```

---

## Connecting to Redshift

After the workgroup is created, the endpoint appears in the Terraform output:

```bash
terraform output -raw workgroup_endpoint
# Returns something like: edp-dev-workgroup.abc123.eu-central-1.redshift-serverless.amazonaws.com
```

This hostname is the address SQL clients use to connect. The port is 5439.

**From the AWS console:** The Redshift Serverless console has a built-in query editor. No VPN or SSH tunnel needed for quick testing.

**From dbt:** Add the workgroup endpoint and credentials to the dbt profile (in `~/.dbt/profiles.yml`). dbt connects over port 5439 using the Redshift adapter.

**From psql (PostgreSQL command line tool):**

```bash
psql -h <workgroup_endpoint> -p 5439 -U admin -d edp
```

Since Redshift is not publicly accessible, you would need to run this from inside the VPC (for example, from a bastion host or from Cloud9 inside the VPC).

---

## Sensitive variables

`redshift_admin_password` has no default and must be provided at apply time. Never put it in a `.tf` file or commit it to Git.

**Recommended — environment variable:**

```bash
export TF_VAR_redshift_admin_password="YourSecurePassword456!"
make apply dev
```

**After `apply` completes**, Terraform stores the password in SSM Parameter Store at `/edp/dev/redshift/admin_password`. From that point on, all tools fetch it from SSM — no password file ever needs to exist.

**Alternative — tfvars file (excluded from Git):**

```bash
# In environments/dev/secret.tfvars (added to .gitignore)
db_password              = "YourSecurePassword123!"
redshift_admin_password  = "YourSecurePassword456!"

terraform apply -var-file="secret.tfvars"
```

---

## Module inputs (variables)

| Variable | Type | Default | Description |
|---|---|---|---|
| `environment` | string | required | `dev`, `staging`, or `prod` |
| `name_prefix` | string | required | Short prefix for all resource names |
| `vpc_id` | string | required | VPC ID from the `networking` module |
| `vpc_cidr` | string | required | VPC CIDR from the `networking` module, used to restrict Redshift ingress |
| `private_subnet_ids` | list(string) | required | Private subnet IDs from the `networking` module |
| `kms_key_arn` | string | required | KMS key ARN from the `iam-metadata` module |
| `redshift_role_arn` | string | required | Redshift IAM role ARN from the `iam-metadata` module |
| `redshift_admin_username` | string | `admin` | Admin username for the namespace |
| `redshift_admin_password` | string | required | Admin password (sensitive, never commit) |
| `redshift_db_name` | string | `edp` | Default database name inside the namespace |
| `base_capacity_rpus` | number | `8` | Base compute capacity in RPUs. Minimum is 8. |

---

## Module outputs

| Output | Used by |
|---|---|
| `namespace_name` | Reference in other Terraform resources or for CLI commands |
| `workgroup_name` | dbt profile configuration, Airflow connections |
| `workgroup_endpoint` | SQL clients, dbt, BI tools use this hostname to connect |
| `redshift_security_group_id` | Available if another module needs to allow traffic to Redshift |
| `ssm_redshift_password_path` | The SSM parameter path where the admin password is stored: `/edp/{env}/redshift/admin_password` |

---

## How to deploy

```bash
aws sso login --profile dev-admin

# From inside terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

The environment's `main.tf` calls this module like this:

```hcl
module "serving" {
  source                  = "../../modules/serving"
  environment             = var.environment
  name_prefix             = var.name_prefix
  vpc_id                  = module.networking.vpc_id
  vpc_cidr                = var.vpc_cidr
  private_subnet_ids      = module.networking.private_subnet_ids
  kms_key_arn             = module.iam_metadata.kms_key_arn
  redshift_role_arn       = module.iam_metadata.redshift_role_arn
  redshift_admin_password = var.redshift_admin_password
}
```

---

## Validation checklist

After `terraform apply`, I check the following in the AWS console:

**Redshift Serverless console:**
- [ ] Namespace `edp-dev-namespace` exists
- [ ] Workgroup `edp-dev-workgroup` exists
- [ ] Workgroup status: Available
- [ ] Workgroup is not publicly accessible
- [ ] Base capacity: 8 RPUs (or whatever value was set)
- [ ] Subnets: two private subnets listed
- [ ] IAM role: `edp-dev-redshift-role` is attached to the namespace
- [ ] Encryption: KMS key is set

**SSM (Systems Manager) console:**
- [ ] Parameter `/edp/dev/redshift/admin_password` exists as a `SecureString`

**Connection test:**
- [ ] Run a test query in the Redshift query editor: `SELECT current_database();`
- [ ] Result returns: `edp`

---

## What comes next

After the serving module is deployed, the next step is the `orchestration` module, which creates the MWAA (Amazon Managed Workflows for Apache Airflow) environment. Airflow is the scheduler that runs the Glue jobs and coordinates the full pipeline automatically.

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | Redshift security group, Redshift Serverless namespace, Redshift Serverless workgroup |
| `variables.tf` | Input variable declarations including the sensitive admin password |
| `outputs.tf` | Exports namespace name, workgroup name, endpoint hostname, and security group ID |
