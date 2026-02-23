# Networking Module — Enterprise Data Platform

## Overview

This module provisions the foundational networking layer for the Enterprise Data Platform (EDP) inside Amazon Web Services (AWS).

EDP stands for **Enterprise Data Platform**.

This networking layer is mandatory because all compute services (AWS Glue, Amazon Redshift Serverless, Amazon MWAA) require controlled network boundaries, subnet placement, and secure access to Amazon S3.

Without networking:

* Services cannot communicate securely
* There is no isolation
* There is no routing control
* There is no private access to S3

This module implements enterprise-grade Virtual Private Cloud (VPC) design.

---

# Architecture Summary

Region: eu-central-1 (Frankfurt)

CIDR Block: 10.10.0.0/16

Subnets:

* 1 Public Subnet
* 2 Private Subnets (Multi Availability Zone)

Routing:

* Public subnet → Internet Gateway
* Private subnets → No internet route
* Private subnets → S3 Gateway Endpoint

This ensures:

* Secure compute placement
* No unintended internet access
* Cost-efficient S3 access

---

# Why Networking Is Required

AWS services operate inside a VPC (Virtual Private Cloud).

A VPC allows you to define:

* IP address space
* Subnet segmentation
* Routing rules
* Internet access rules
* Private service access

Enterprise data platforms must:

* Prevent direct internet exposure
* Restrict egress traffic
* Support high availability across Availability Zones (AZ)
* Enable private access to Amazon S3

This module satisfies those requirements.

---

# Module Structure

modules/networking/

Files:

* main.tf
* variables.tf
* outputs.tf

The module is environment-agnostic and is instantiated inside:

environments/dev
environments/staging
environments/prod

---

# Resources Created

## 1. AWS VPC (Virtual Private Cloud)

Resource: aws_vpc

Purpose:
Creates a logically isolated network inside AWS.

Configuration:

* CIDR block defined by variable
* DNS support enabled
* DNS hostnames enabled

Why DNS is enabled:
Managed services like AWS Glue and Amazon Redshift require internal DNS resolution.

---

## 2. Internet Gateway (IGW)

Resource: aws_internet_gateway

Purpose:
Allows public subnet to communicate with the internet.

Important:
Private subnets do NOT use this gateway.

---

## 3. Public Subnet

Resource: aws_subnet (public)

Purpose:
Hosts infrastructure that may require public routing.

Configuration:

* Public IP auto-assignment enabled
* Routed to Internet Gateway

This subnet is NOT used for compute workloads.

---

## 4. Private Subnet A

Resource: aws_subnet (private_a)

Purpose:
Hosts compute services.

Availability Zone: eu-central-1a

---

## 5. Private Subnet B

Resource: aws_subnet (private_b)

Purpose:
Hosts compute services for high availability.

Availability Zone: eu-central-1b

Multi-AZ deployment ensures:

* Fault tolerance
* Service continuity
* Redshift Serverless compatibility

---

## 6. Route Tables

### Public Route Table

Routes:
0.0.0.0/0 → Internet Gateway

Purpose:
Allow outbound internet access for public subnet.

### Private Route Table

No default route to internet.

Purpose:
Private subnets remain isolated.

---

## 7. S3 Gateway VPC Endpoint

Resource: aws_vpc_endpoint

Type: Gateway

Service: com.amazonaws.eu-central-1.s3

Purpose:
Allows private subnets to access Amazon S3 without:

* NAT Gateway
* Public internet exposure

Benefits:

* Lower cost
* Increased security
* Reduced attack surface

---

# Naming Convention

Prefix: edp

edp = Enterprise Data Platform

Naming pattern:

edp-<environment>-<resource-type>

Examples:

* edp-dev-vpc
* edp-dev-private-a
* edp-dev-s3-endpoint

This ensures:

* Environment visibility
* Clear ownership
* Predictable resource identification

---

# CIDR Subnetting Logic

Base CIDR:
10.10.0.0/16

Subnets created using cidrsubnet function:

10.10.0.0/20  → Public
10.10.16.0/20 → Private A
10.10.32.0/20 → Private B

/20 provides 4096 IP addresses per subnet.

This design leaves room for future subnet expansion.

---

# Module Inputs

Variable: environment
Type: string
Purpose: Identifies deployment environment

Variable: vpc_cidr
Type: string
Purpose: Defines VPC IP range

Variable: region
Type: string
Purpose: Defines AWS region

---

# Module Outputs

Output: vpc_id
Purpose: Used by downstream modules

Output: private_subnet_ids
Purpose: Required by:

* AWS Glue
* Amazon Redshift Serverless
* Amazon MWAA

Output: public_subnet_id
Purpose: Infrastructure routing (if needed)

---

# Deployment Steps

1. Authenticate

aws sso login --profile dev-admin

2. Navigate to environment

cd environments/dev

3. Initialize Terraform

terraform init

Purpose:

* Configure remote backend
* Install providers
* Register modules

4. Preview changes

terraform plan

Purpose:

* Review infrastructure changes

5. Apply

terraform apply

Purpose:

* Create infrastructure

---

# Why No NAT Gateway?

NAT = Network Address Translation

NAT allows private subnets to access public internet.

We intentionally avoid NAT because:

* It increases cost
* Our services only require S3 access
* S3 Gateway Endpoint satisfies requirement

This is a cost-efficient enterprise decision.

---

# Validation Checklist

After deployment verify in AWS Console:

* VPC exists
* CIDR is correct
* Public subnet has internet route
* Private subnets have no internet route
* S3 endpoint attached to private route table

---

# Next Module

After networking is verified, proceed to:

Data Lake Module

Which will provision:

* Bronze bucket
* Silver bucket
* Gold bucket
* Quarantine bucket
* Bucket policies
* Lifecycle rules

Networking must exist before data lake.

---

# Summary

This module establishes:

* Network isolation
* High availability
* Private S3 access
* Enterprise naming standards
* Terraform modular architecture

It is the foundation upon which all other platform services will be deployed.

---

#  Data Lake Module — Enterprise Medallion Storage (Terraform)

---

# 1️ Purpose of This Module

The **Data Lake module** provisions the storage foundation of the Enterprise Data Platform.

It creates a secure, environment-isolated, production-grade medallion architecture using:

- Amazon S3 (object storage)
- Encryption at rest
- Versioning
- Public access blocking
- Deterministic naming
- Terraform-managed lifecycle

This module is designed following strict enterprise principles:

- Structure before services
- Environment isolation
- No public exposure
- No manual console creation
- Fully reproducible via Terraform

---

# 2️ What Problem This Module Solves

After networking is provisioned, we need durable storage for:

- Raw Change Data Capture (CDC)
- Cleaned transformation outputs
- Aggregated analytical datasets
- Invalid data isolation
- Controlled SQL query results

Without this module:

- Glue cannot write data
- Athena cannot query structured datasets
- Redshift cannot COPY from curated storage
- There is no system of record

This module establishes the storage layer of the platform.

---

# 3️ Architecture Overview

We implement a strict **Medallion Architecture**:

| Layer | Purpose |
|-------|----------|
| Bronze | Immutable raw CDC events |
| Silver | Cleaned & structured datasets |
| Gold | Business aggregates |
| Quarantine | Invalid or failed records |
| Athena Results | Controlled SQL output location |

Each layer is provisioned as an independent S3 bucket for:

- IAM isolation
- Blast-radius containment
- Lifecycle control
- Clear governance boundaries

---

# 4️ Module Structure

```

modules/
  data-lake/
    main.tf
    variables.tf
    outputs.tf

```

Environment composition:

```

environments/
  dev/
    main.tf
  staging/
    main.tf
  prod/
    main.tf

```

---

# 5 variables.tf

```

######################################################
# Environment Name
######################################################

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

######################################################
# Allow Force Destroy (Dev Only)
######################################################

variable "force_destroy" {
  description = "Allow bucket deletion even if non-empty (true only in dev)"
  type        = bool
  default     = false
}

```

## Explanation

environment  
Ensures naming isolation between dev, staging, and prod.

force_destroy  
Prevents destructive deletion in staging and production.  
Should be set to true only in development.

---

# 6 main.tf (Complete Logic)

```

######################################################
# DATA LAKE MODULE — ENTERPRISE MEDALLION STORAGE
######################################################

######################################################
# Current AWS Account Identity
######################################################

data "aws_caller_identity" "current" {}

######################################################
# Local Naming Convention
######################################################

locals {
  bronze_bucket         = "edp-emeka-${var.environment}-bronze"
  silver_bucket         = "edp-emeka-${var.environment}-silver"
  gold_bucket           = "edp-emeka-${var.environment}-gold"
  quarantine_bucket     = "edp-emeka-${var.environment}-quarantine"
  athena_results_bucket = "edp-emeka-${var.environment}-athena-results"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "Emeka"
    Project     = "EnterpriseDataPlatform"
    AccountID   = data.aws_caller_identity.current.account_id
  }
}

######################################################
# Bronze Bucket — Raw CDC
######################################################

resource "aws_s3_bucket" "bronze" {
  bucket        = local.bronze_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.bronze_bucket
    Layer = "Bronze"
  })
}

######################################################
# Silver Bucket — Cleaned Data
######################################################

resource "aws_s3_bucket" "silver" {
  bucket        = local.silver_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.silver_bucket
    Layer = "Silver"
  })
}

######################################################
# Gold Bucket — Business Aggregates
######################################################

resource "aws_s3_bucket" "gold" {
  bucket        = local.gold_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.gold_bucket
    Layer = "Gold"
  })
}

######################################################
# Quarantine Bucket — Invalid Records
######################################################

resource "aws_s3_bucket" "quarantine" {
  bucket        = local.quarantine_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.quarantine_bucket
    Layer = "Quarantine"
  })
}

######################################################
# Athena Results Bucket
######################################################

resource "aws_s3_bucket" "athena_results" {
  bucket        = local.athena_results_bucket
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name  = local.athena_results_bucket
    Layer = "QueryResults"
  })
}

######################################################
# Encryption Configuration (All Buckets)
######################################################

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

######################################################
# Versioning (All Buckets)
######################################################

resource "aws_s3_bucket_versioning" "all" {
  for_each = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    quarantine     = aws_s3_bucket.quarantine.id
    athena_results = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

######################################################
# Public Access Block (All Buckets)
######################################################

resource "aws_s3_bucket_public_access_block" "all" {
  for_each = {
    bronze         = aws_s3_bucket.bronze.id
    silver         = aws_s3_bucket.silver.id
    gold           = aws_s3_bucket.gold.id
    quarantine     = aws_s3_bucket.quarantine.id
    athena_results = aws_s3_bucket.athena_results.id
  }

  bucket = each.value

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

```

---

# 7 outputs.tf

```

output "bronze_bucket_name" {
  value = aws_s3_bucket.bronze.bucket
}

output "silver_bucket_name" {
  value = aws_s3_bucket.silver.bucket
}

output "gold_bucket_name" {
  value = aws_s3_bucket.gold.bucket
}

output "quarantine_bucket_name" {
  value = aws_s3_bucket.quarantine.bucket
}

output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}

```

## Why Outputs Matter

These outputs allow downstream modules to:

- Reference bucket names
- Attach IAM policies
- Configure Glue jobs
- Configure Athena workgroups
- Configure Redshift COPY commands

No bucket name should ever be hardcoded outside this module.

---

# 8 Environment Composition Example (dev)

```

module "data_lake" {
  source        = "../../modules/data-lake"
  environment   = "dev"
  force_destroy = true
}

```

Staging and production:

```

module "data_lake" {
  source        = "../../modules/data-lake"
  environment   = "staging"
  force_destroy = false
}

```

---

# 9 Security Controls Implemented

This module enforces:

- Encryption at rest (AES256)
- Versioning enabled
- Public access completely blocked
- No public ACLs
- No public policies
- Terraform-only provisioning
- Environment isolation

These are considered **minimum enterprise storage controls**.

---

#  What We Achieved

After applying this module, we now have:

- Fully provisioned medallion storage
- Secure, private S3 buckets
- Deterministic naming
- Governance-ready architecture
- Downstream integration capability

At this stage, the platform includes:

- Networking (VPC + private subnets)
- Secure Data Lake (Medallion S3 buckets)

The next logical layer is:

Metadata (Glue Data Catalog + Athena Workgroup)

This will allow structured querying of the Silver and Gold layers.

---

# 10 Deployment Commands

```

aws sso login --profile dev-admin
cd environments/dev
terraform init
terraform plan
terraform apply

```

---

# 11 Manual Validation Checklist

After apply, verify in AWS Console:

- 5 buckets exist
- Encryption enabled
- Versioning enabled
- Public access fully blocked
- Proper naming pattern
- Correct tags applied
- No public policies attached

If all checks pass, the storage layer is production-ready.