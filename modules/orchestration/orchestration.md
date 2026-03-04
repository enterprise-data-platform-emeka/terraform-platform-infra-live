# Module: orchestration

**Location:** `terraform-platform-infra-live/modules/orchestration/`

**Depends on:** `networking` (vpc_id, private_subnet_ids), `iam-metadata` (kms_key_arn, mwaa_role_arn)

---

## What this module does

This module creates the pipeline scheduler for the platform: Amazon MWAA (Managed Workflows for Apache Airflow). MWAA is a fully managed version of Apache Airflow, which is the most widely used open-source workflow scheduling tool in data engineering.

Airflow's job is to run things in the right order at the right time. For example: every night at 2 AM, run the Glue (AWS Glue is a managed data integration service) Bronze-to-Silver job. When that finishes, run the Silver-to-Gold dbt (data build tool) job. When that finishes, send a Slack notification. If any step fails, stop the pipeline and alert the team.

This module creates four resources:

1. **A DAGs S3 (Simple Storage Service) bucket** — where I upload the Airflow DAG (Directed Acyclic Graph, which is an Airflow workflow file) Python files
2. **CloudWatch (Amazon's monitoring and logging service) log groups** — one for each Airflow component (scheduler, worker, webserver, DAG processor)
3. **A security group for MWAA** — controls what network traffic is allowed in and out of the MWAA workers
4. **The MWAA environment** — the actual managed Airflow deployment

---

## What is a DAG?

A DAG (Directed Acyclic Graph) is an Airflow workflow file written in Python. The name comes from graph theory: it is a graph where steps flow in one direction (directed) and never loop back (acyclic).

Here is what a simple DAG looks like:

```python
from airflow import DAG
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator
from datetime import datetime

with DAG("bronze_to_silver", schedule="0 2 * * *", start_date=datetime(2024, 1, 1)):
    run_glue = GlueJobOperator(
        task_id="run_bronze_to_silver",
        job_name="edp-dev-bronze-to-silver",
        region_name="eu-central-1"
    )
```

This DAG runs the Glue job called `edp-dev-bronze-to-silver` every night at 2 AM. Airflow handles retries, dependency tracking, and logging automatically.

DAG files live in the `platform-orchestration-mwaa-airflow` repository. To deploy a new DAG, I upload the Python file to the DAGs S3 bucket. MWAA detects the new file within 30 seconds and starts scheduling it.

---

## Resources created

### 1. DAGs S3 bucket

```hcl
resource "aws_s3_bucket" "dags" {
  bucket        = local.dags_bucket_name
  force_destroy = var.force_destroy
}
```

The bucket name follows the same naming formula as the data lake buckets: `{name_prefix}-{environment}-{account_id}-mwaa-dags`. For example: `edp-dev-123456789012-mwaa-dags`.

The account ID is included because S3 bucket names are globally unique across all AWS accounts worldwide.

I apply the same three protections to this bucket as to the data lake buckets:

**Versioning:** Every version of every DAG file is kept. If I push a broken DAG, I can roll back to the previous working version.

**Encryption:** Files are encrypted using the platform KMS (Key Management Service) key. Unlike the data lake buckets which use `AES256` (AWS-managed encryption), this bucket uses `aws:kms` encryption because MWAA requires KMS encryption on the DAGs bucket.

**Public access block:** All four public access settings are turned on. No public access is possible under any circumstances.

**`force_destroy`:** In dev, this is `true` so I can run `terraform destroy` and clean everything up. In staging and prod, this is `false` to protect real pipeline files.

---

### 2. CloudWatch log groups

```hcl
resource "aws_cloudwatch_log_group" "mwaa_scheduler" {
  name              = "/aws/mwaa/${var.name_prefix}-${var.environment}/scheduler"
  retention_in_days = var.log_retention_days
}
```

I create four log groups, one for each Airflow component:

| Log group | What it contains |
|---|---|
| `/scheduler` | Airflow scheduler decisions: which DAGs were triggered, which tasks were queued |
| `/webserver` | Airflow web UI access logs |
| `/worker` | Task execution logs: the actual output of each Airflow task |
| `/dag-processor` | Logs from Airflow reading and parsing the DAG Python files |

**Why I create these in Terraform rather than letting MWAA create them automatically:** I set `retention_in_days = 30`. Without an explicit retention period, CloudWatch keeps logs forever and storage costs grow continuously. 30 days is enough to debug most problems and investigate recent pipeline failures.

---

### 3. Security group for MWAA

```hcl
resource "aws_security_group" "mwaa" {
  name   = "${var.name_prefix}-${var.environment}-mwaa-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Like the Glue security group, MWAA requires a self-referencing ingress rule. MWAA runs multiple internal components (scheduler, workers, webserver) that communicate with each other over the network. The `self = true` rule allows any resource in this security group to send traffic to any other resource in the same security group on any port.

The egress rule allows all outbound traffic. The private subnets have no NAT (Network Address Translation) gateway, so in practice MWAA can only reach S3 via the VPC (Virtual Private Cloud) endpoint and AWS service APIs via internal AWS routing. No traffic can reach the public internet.

---

### 4. MWAA environment

```hcl
resource "aws_mwaa_environment" "this" {
  name              = "${var.name_prefix}-${var.environment}-mwaa"
  airflow_version   = var.airflow_version
  environment_class = var.mwaa_environment_class

  dag_s3_path        = "dags/"
  source_bucket_arn  = aws_s3_bucket.dags.arn
  execution_role_arn = var.mwaa_role_arn

  kms_key = var.kms_key_arn

  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    subnet_ids         = var.private_subnet_ids
  }

  logging_configuration { ... }

  airflow_configuration_options = {
    "core.load_examples" = "false"
  }
}
```

**`airflow_version`:** The version of Apache Airflow to run. I use 2.9.2. AWS maintains a list of supported versions. I pin a specific version so I know exactly which Airflow features and operators are available.

**`environment_class`:** Controls the size of the MWAA scheduler and worker instances. I use `mw1.small`, which is the smallest and cheapest option. It is enough for development and light workloads.

| Class | vCPU | Memory | Use case |
|---|---|---|---|
| `mw1.small` | 2 | 4 GB | Development, light workloads |
| `mw1.medium` | 4 | 8 GB | Moderate workloads |
| `mw1.large` | 8 | 16 GB | Heavy workloads |

**`dag_s3_path = "dags/"`:** MWAA looks for DAG files under the `dags/` prefix in the source bucket. I upload my DAG Python files to `s3://edp-dev-{account_id}-mwaa-dags/dags/`.

**`source_bucket_arn`:** The DAGs bucket created above. MWAA polls this bucket every 30 seconds for new or changed DAG files.

**`execution_role_arn`:** The IAM (Identity and Access Management) role MWAA uses when running tasks. This is the `mwaa_role_arn` from the `iam-metadata` module, which grants MWAA permission to trigger Glue jobs, read the DAGs bucket, and write CloudWatch logs.

**`kms_key`:** MWAA encrypts environment variables and connection strings using the platform KMS key.

**`logging_configuration`:** Enables all five log types (DAG processing, scheduler, task, webserver, worker) at INFO level. These logs go to the CloudWatch log groups created above.

**`airflow_configuration_options`:** Airflow has hundreds of configuration options. I set `core.load_examples = false` to prevent Airflow from loading its built-in example DAGs, which would clutter the UI. The rest of the Airflow defaults are sensible and I leave them as-is.

**`depends_on`:** The MWAA environment creation requires the DAGs bucket to have versioning enabled and the CloudWatch log groups to already exist. I list them explicitly in `depends_on` to guarantee Terraform creates them first.

---

## Warning: MWAA takes 20 to 30 minutes to create

When I run `terraform apply` with the orchestration module for the first time, the MWAA environment takes 20 to 30 minutes to become available. This is normal. AWS is creating the underlying Airflow infrastructure, which involves provisioning multiple EC2 (Elastic Compute Cloud) instances and setting up internal networking.

The Terraform apply will appear to hang during this time. It is not frozen. It is waiting for MWAA to report `Available` status. I can watch the progress in the MWAA console.

---

## MWAA cost warning

MWAA is the most expensive service in this platform. The `mw1.small` environment costs approximately $0.49 per hour regardless of whether any DAGs are running. That is about $11.76 per day or $353 per month.

**My approach for cost management:** I only start MWAA when I need to test pipeline scheduling. For day-to-day development, I run Airflow locally on my laptop:

```bash
pip install apache-airflow
airflow standalone
```

The local Airflow instance reads the same DAG files and uses the same operators, so I can develop and test DAGs without paying for MWAA. I only deploy to MWAA to test the real cloud integration (Glue triggering, S3 bucket interactions, CloudWatch logging).

When not actively testing, I run `terraform destroy` to stop the MWAA environment and avoid ongoing costs.

---

## Accessing the Airflow UI

After the MWAA environment is available, the webserver URL appears in the Terraform output:

```bash
terraform output mwaa_webserver_url
```

Open this URL in a browser. AWS uses IAM authentication for the MWAA web UI. My SSO (Single Sign-On) session credentials automatically grant access as long as I have the correct IAM permissions.

---

## Uploading a DAG

To deploy a DAG file to the running MWAA environment:

```bash
aws s3 cp my_dag.py s3://edp-dev-{account_id}-mwaa-dags/dags/ --profile dev-admin
```

MWAA picks up the file within 30 seconds. The DAG then appears in the Airflow UI.

---

## Module inputs (variables)

| Variable | Type | Default | Description |
|---|---|---|---|
| `environment` | string | required | `dev`, `staging`, or `prod` |
| `name_prefix` | string | required | Short prefix for all resource names |
| `vpc_id` | string | required | VPC ID from the `networking` module |
| `private_subnet_ids` | list(string) | required | Private subnet IDs from the `networking` module |
| `kms_key_arn` | string | required | KMS key ARN from the `iam-metadata` module |
| `mwaa_role_arn` | string | required | MWAA execution role ARN from the `iam-metadata` module |
| `airflow_version` | string | `2.9.2` | Apache Airflow version |
| `mwaa_environment_class` | string | `mw1.small` | MWAA instance size |
| `log_retention_days` | number | `30` | How many days CloudWatch retains MWAA logs |
| `force_destroy` | bool | `false` | Allow DAGs bucket deletion even when it has files. Set `true` for dev. |

---

## Module outputs

| Output | Used by |
|---|---|
| `mwaa_environment_name` | Reference in CLI commands or other Terraform resources |
| `mwaa_webserver_url` | Open in a browser to access the Airflow UI |
| `dags_bucket_name` | Upload DAG files here: `aws s3 cp dag.py s3://{bucket}/dags/` |
| `dags_bucket_arn` | Available if another resource needs to reference the bucket ARN |
| `mwaa_security_group_id` | Available if another module needs to allow traffic to MWAA |

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
module "orchestration" {
  source             = "../../modules/orchestration"
  environment        = var.environment
  name_prefix        = var.name_prefix
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  kms_key_arn        = module.iam_metadata.kms_key_arn
  mwaa_role_arn      = module.iam_metadata.mwaa_role_arn
  force_destroy      = true  # dev only
}
```

---

## Validation checklist

After `terraform apply` completes (allow 20 to 30 minutes):

**MWAA console:**
- [ ] Environment `edp-dev-mwaa` is in `Available` state
- [ ] Airflow version matches the variable
- [ ] Environment class matches the variable
- [ ] Subnets: two private subnets listed
- [ ] Webserver URL is shown

**S3 console:**
- [ ] Bucket `edp-dev-{account_id}-mwaa-dags` exists
- [ ] Versioning: Enabled
- [ ] Encryption: aws:kms (using platform key)
- [ ] Public access: all four settings blocked

**CloudWatch console, Log groups:**
- [ ] `/aws/mwaa/edp-dev/scheduler` exists with 30-day retention
- [ ] `/aws/mwaa/edp-dev/webserver` exists with 30-day retention
- [ ] `/aws/mwaa/edp-dev/worker` exists with 30-day retention
- [ ] `/aws/mwaa/edp-dev/dag-processor` exists with 30-day retention

**Airflow UI:**
- [ ] Open the webserver URL in a browser
- [ ] UI loads and shows no example DAGs
- [ ] No error messages in the scheduler logs

---

## What comes next

With all seven Terraform modules now deployed, the infrastructure layer is complete. The next phase is writing the application code that actually processes data:

1. **`platform-glue-jobs`** — PySpark (a Python API for Apache Spark) job that reads Bronze, resolves CDC (Change Data Capture) operations, validates the schema, and writes clean records to Silver
2. **`platform-dbt-analytics`** — dbt SQL models that read Silver via Athena and write aggregated results to Gold
3. **`platform-orchestration-mwaa-airflow`** — Airflow DAG files that schedule and coordinate the full pipeline

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | DAGs S3 bucket, CloudWatch log groups, MWAA security group, MWAA environment |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Exports the MWAA environment name, webserver URL, DAGs bucket name, and security group ID |
