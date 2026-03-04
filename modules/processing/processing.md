# Module: processing

**Location:** `terraform-platform-infra-live/modules/processing/`

**Depends on:** `networking` (vpc_id, private_subnet_ids), `iam-metadata` (kms_key_arn), `data-lake` (athena_results_bucket)

---

## What this module does

This module sets up the environment that Glue (AWS Glue is a managed data integration service) jobs and Athena (Amazon Athena is AWS's serverless SQL query engine) need to run. It does not create any Glue jobs themselves. Those jobs live in the `platform-glue-jobs` repository as PySpark (a Python API for Apache Spark, a distributed data processing engine) code. What this module creates is the infrastructure those jobs plug into.

Specifically, this module creates three things:

1. **A Glue security configuration** — tells Glue to encrypt everything it writes using the platform KMS (Key Management Service) key
2. **A Glue VPC (Virtual Private Cloud) connection** — tells Glue which private subnet and security group to run jobs in, so jobs can reach the RDS (Relational Database Service) source database and other VPC resources
3. **An Athena workgroup** — groups all SQL queries together, enforces that query results go to the correct S3 (Simple Storage Service) bucket, and enforces encryption on those results

---

## Why these three things are needed

**Without the Glue security configuration:** Glue jobs write CloudWatch logs, job bookmark files, and output data in plain text. No encryption. Any data that lands in S3 during a Glue run would not be protected by the platform KMS key.

**Without the Glue VPC connection:** Glue runs in AWS-managed shared infrastructure that has no route into my private VPC. A Glue job that tries to read from RDS (to validate or enrich data) would fail because it cannot reach the database. By giving Glue a VPC connection, Glue jobs run inside my private subnets and can reach everything in the VPC.

**Without the Athena workgroup:** Every Athena query would go to the default workgroup, which writes results to a default location in S3 that I have no control over. With a named workgroup, I control exactly where results go, who can run queries, and what encryption is applied.

---

## Resources created

### 1. Security group for Glue

```hcl
resource "aws_security_group" "glue" {
  name   = "${var.name_prefix}-${var.environment}-glue-sg"
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

A security group is a virtual firewall attached to a service that controls what network traffic is allowed in and out.

**The self-referencing ingress rule (`self = true`):** When a Glue PySpark job runs, it starts multiple worker processes (called executors). These workers need to communicate with each other to coordinate the distributed computation. The `self = true` rule means: allow inbound traffic on any port from any resource that is also a member of this security group. This is how the Glue workers talk to each other.

This self-referencing rule is a requirement from AWS. Without it, Glue job runs fail with a connectivity error between workers.

**The egress rule (`0.0.0.0/0`):** Allows all outbound traffic. In practice, since the private subnets have no NAT (Network Address Translation) gateway and no internet route, Glue jobs can only reach S3 (through the S3 Gateway VPC Endpoint created in the networking module) and other resources inside the VPC. The broad egress rule does not open the internet; the route table controls what actually goes where.

---

### 2. Glue security configuration

```hcl
resource "aws_glue_security_configuration" "this" {
  name = "${var.name_prefix}-${var.environment}-glue-sec-config"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
  }
}
```

A Glue security configuration is a named object that Glue job definitions reference by name. When a job is created with a security configuration attached, Glue automatically applies the encryption settings in that configuration to everything the job produces.

**Three encryption settings:**

**`cloudwatch_encryption` with `SSE-KMS`:** Glue writes execution logs to CloudWatch (Amazon's monitoring and logging service). SSE-KMS (Server-Side Encryption with KMS) means CloudWatch encrypts those log entries using the platform KMS key before storing them. Anyone who can see the logs also needs access to the KMS key to read them.

**`job_bookmarks_encryption` with `CSE-KMS`:** Glue job bookmarks are checkpoints that track how far a job has processed. If a job runs daily and fails halfway through, the bookmark lets it resume from where it stopped rather than reprocessing everything from the start. CSE-KMS (Client-Side Encryption with KMS) means Glue encrypts the bookmark data on the client side before sending it to AWS, so even the storage layer cannot read it without the key.

**`s3_encryption` with `SSE-KMS`:** When a Glue job writes output to S3 (for example, writing cleaned records to the Silver bucket), Glue encrypts those files using the platform KMS key. This is the most important setting because it covers the actual data files.

---

### 3. Glue VPC connection

```hcl
resource "aws_glue_connection" "vpc" {
  name            = "${var.name_prefix}-${var.environment}-glue-vpc-connection"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.private_a.availability_zone
    security_group_id_list = [aws_security_group.glue.id]
    subnet_id              = var.private_subnet_ids[0]
  }
}
```

A Glue VPC connection (with `connection_type = "NETWORK"`) is a configuration object that tells Glue to launch job workers inside a specific subnet and security group rather than in AWS's shared infrastructure.

**`availability_zone`:** Glue needs to know which AZ (Availability Zone, which is an independent data centre within the same AWS region) to launch workers in. I derive this automatically from the subnet using a data source:

```hcl
data "aws_subnet" "private_a" {
  id = var.private_subnet_ids[0]
}
```

This looks up the AZ of the first private subnet without hardcoding it.

**`subnet_id`:** The specific private subnet where Glue workers run. I use the first private subnet.

**`security_group_id_list`:** The Glue security group created above, which includes the self-referencing rule that Glue workers require.

When a Glue job references this connection by name in its definition, Glue launches its workers into this subnet and security group. The workers can then reach RDS (port 5432), other VPC services, and S3 (through the VPC endpoint).

---

### 4. Athena workgroup

```hcl
resource "aws_athena_workgroup" "this" {
  name  = "${var.name_prefix}-${var.environment}-workgroup"
  state = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${var.athena_results_bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key           = var.kms_key_arn
      }
    }
  }
}
```

An Athena workgroup is a named configuration that groups related queries together. It controls where query results are stored, whether results are encrypted, and what metrics are published.

**`enforce_workgroup_configuration = true`:** This is the most important setting. It means individual callers cannot override the workgroup settings. Even if someone runs an Athena query and specifies a different output location, Athena ignores that and uses the workgroup's location instead. This guarantees all query results always go to the athena-results bucket.

**`publish_cloudwatch_metrics_enabled = true`:** Athena publishes metrics to CloudWatch such as query execution time and data scanned per query. These metrics help me track costs (Athena charges per terabyte scanned) and spot slow or expensive queries.

**`output_location`:** All query results are written under `s3://{athena-results-bucket}/query-results/`. This is the same bucket the `data-lake` module created specifically for this purpose.

**`encryption_configuration` with `SSE_KMS`:** Query results are encrypted using the platform KMS key. This includes result files downloaded from the Athena console.

---

## How Glue jobs use these resources

When I write a Glue job definition (in the `platform-glue-jobs` repository), it references the resources created by this module by name:

```python
# In the Glue job definition (infrastructure code, not PySpark code):
glue_client.create_job(
    Name="edp-dev-bronze-to-silver",
    Role="edp-dev-glue-role",                              # from iam-metadata
    SecurityConfiguration="edp-dev-glue-sec-config",       # from this module
    Connections={"Connections": ["edp-dev-glue-vpc-connection"]},  # from this module
    ...
)
```

The PySpark job code itself does not know about security configurations or VPC connections. It just reads and writes data. The infrastructure handles the encryption and network routing transparently.

---

## Module inputs (variables)

| Variable | Type | Description |
|---|---|---|
| `environment` | string | Environment name: `dev`, `staging`, or `prod` |
| `name_prefix` | string | Short prefix for all resource names, for example `edp` |
| `vpc_id` | string | VPC ID from the `networking` module |
| `private_subnet_ids` | list(string) | Private subnet IDs from the `networking` module |
| `kms_key_arn` | string | KMS key ARN from the `iam-metadata` module |
| `athena_results_bucket` | string | Athena results bucket name from the `data-lake` module |

---

## Module outputs

| Output | Used by |
|---|---|
| `glue_security_configuration_name` | Glue job definitions in `platform-glue-jobs` reference this by name |
| `glue_connection_name` | Glue job definitions reference this by name to run in the VPC |
| `glue_security_group_id` | Can be used to add an ingress rule to the RDS security group allowing Glue to connect on port 5432 |
| `athena_workgroup_name` | dbt (data build tool) configuration and direct Athena query tools reference this |

---

## How to deploy

This module is deployed as part of an environment, not on its own.

```bash
aws sso login --profile dev-admin
```

SSO (Single Sign-On) refreshes my temporary AWS credentials before running Terraform.

```bash
# From inside terraform-platform-infra-live/
make init dev
make plan dev
make apply dev
```

The environment's `main.tf` calls this module like this:

```hcl
module "processing" {
  source                = "../../modules/processing"
  environment           = var.environment
  name_prefix           = var.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  kms_key_arn           = module.iam_metadata.kms_key_arn
  athena_results_bucket = module.data_lake.athena_results_bucket
}
```

---

## Validation checklist

After `terraform apply`, I check the following in the AWS console:

**Glue console, Security configurations:**
- [ ] `edp-dev-glue-sec-config` exists
- [ ] CloudWatch encryption: SSE-KMS with the platform key
- [ ] Job bookmarks encryption: CSE-KMS with the platform key
- [ ] S3 encryption: SSE-KMS with the platform key

**Glue console, Connections:**
- [ ] `edp-dev-glue-vpc-connection` exists
- [ ] Connection type: Network
- [ ] Subnet: one of the private subnets
- [ ] Status: Ready

**Athena console, Workgroups:**
- [ ] `edp-dev-workgroup` exists
- [ ] State: Enabled
- [ ] Query result location: points to the athena-results bucket
- [ ] Encryption: SSE_KMS

**VPC console, Security groups:**
- [ ] `edp-dev-glue-sg` exists
- [ ] Inbound: self-referencing rule on all TCP ports
- [ ] Outbound: all traffic

---

## What comes next

After the processing module is deployed, the next infrastructure step is the `serving` module, which creates the Redshift Serverless namespace and workgroup that analysts use to run SQL queries against the Gold layer.

The actual Glue PySpark job code (Bronze to Silver transformation) lives in the `platform-glue-jobs` repository and is built after all Terraform infrastructure is complete.

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | Glue security group, Glue security configuration, Glue VPC connection, Athena workgroup |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Exports the security configuration name, connection name, security group ID, and workgroup name |
