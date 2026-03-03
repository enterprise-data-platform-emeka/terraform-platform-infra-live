# Module: networking

**Location:** `terraform-platform-infra-live/modules/networking/`

**Part of:** Terraform Platform Infra — Foundation Layer

---

## What This Module Does

This module creates the private network that all other platform services live inside.

Think of it like building the roads, walls, and plumbing of a building before any furniture (databases, compute, storage) goes in. Nothing else in this platform can be deployed securely without networking existing first.

Specifically, this module creates:

1. A **VPC** (Virtual Private Cloud) — a private, isolated network in AWS
2. An **Internet Gateway** — the door to the public internet (for the public subnet only)
3. One **public subnet** — for future load balancers or bastion hosts
4. Two **private subnets** across two Availability Zones — where all compute services run
5. **Route tables** — the traffic rules defining where data packets go
6. An **S3 Gateway VPC Endpoint** — allows private subnets to reach S3 without internet

---

## Why This Exists — The Problem It Solves

AWS services need a network boundary to operate in. Without a VPC:
- Services have no isolation from each other or the internet
- There is no way to control inbound or outbound traffic
- Services cannot communicate privately with each other
- There is no private access to S3 (you would need an expensive NAT Gateway or expose traffic to the internet)

This module provides all of that in one reusable block.

---

## Resources Created

### 1. `aws_vpc` — The Private Network

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}
```

**What it is:** A VPC is like a private data center network inside AWS. Only resources you explicitly place inside it can communicate with each other.

**`cidr_block`:** Defines the IP address range for the entire network. For dev this is `10.10.0.0/16`, which provides 65,536 available IP addresses.

**`enable_dns_hostnames = true`:** Managed services like Glue and Redshift need to resolve each other's hostnames (e.g., `my-rds-instance.abc.eu-central-1.rds.amazonaws.com`). This setting enables that.

---

### 2. `aws_internet_gateway` — The Internet Door

```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}
```

**What it is:** The gateway that allows outbound traffic from the public subnet to reach the internet, and inbound traffic from the internet to reach the public subnet.

**Important:** The private subnets are NOT connected to this gateway. They have no route to the internet by design. This keeps compute services isolated.

---

### 3. `aws_subnet.public` — The Public Subnet

```hcl
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}
```

**What it is:** A subdivision of the VPC network that has a route to the internet.

**`cidrsubnet(var.vpc_cidr, 4, 0)`:** This function automatically calculates the subnet IP range from the VPC's CIDR. For `10.10.0.0/16` with a `/4` prefix extension, this gives `10.10.0.0/20`.

**When this is used:** Currently reserved for future use (bastion host, load balancer). No data processing happens here. All compute is in the private subnets.

---

### 4. `aws_subnet.private_a` and `aws_subnet.private_b` — The Compute Subnets

```hcl
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 1)
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 2)
  availability_zone = data.aws_availability_zones.available.names[1]
}
```

**What they are:** These are the two subnets where all actual compute services run:
- AWS Glue jobs
- Amazon Redshift Serverless
- Amazon MWAA (Airflow)
- AWS DMS replication instances
- Amazon RDS

**Why two subnets?** AWS requires services like MWAA and Redshift Serverless to span at least two Availability Zones (AZs). An AZ is an independent data center within the same AWS region. If one AZ has an outage, the service continues running in the other AZ. This is called **high availability**.

**Why no internet route?** These subnets have no route to the internet. This means:
- Hackers cannot reach these services directly from the internet
- Services cannot accidentally send data out to the internet
- The only way to reach S3 is through the VPC Endpoint (see below)

---

### 5. `aws_route_table.public` and `aws_route_table.private` — Traffic Rules

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  # No routes — traffic stays inside the VPC only
}
```

**What they are:** Route tables are like GPS rules for network traffic. When a packet arrives, AWS looks up the route table to decide where to send it.

**Public route table:** Has one rule — send all traffic (`0.0.0.0/0`) to the Internet Gateway.

**Private route table:** Has no external routes. Traffic from private subnets can only reach other resources inside the VPC (or S3 via the endpoint below).

**`aws_route_table_association`:** Links the route table to the specific subnet. A subnet without an association uses the VPC's default route table.

---

### 6. `aws_vpc_endpoint.s3` — The S3 Express Lane

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
```

**What it is:** An S3 Gateway Endpoint is a special connection that allows private subnets to reach Amazon S3 without going through the internet.

**Why this matters:** Glue jobs read and write massive amounts of data to S3. Without this endpoint, that traffic would need a NAT Gateway (a device that routes private traffic through a public IP) which costs approximately $32/month per AZ plus data processing fees. The S3 Gateway Endpoint is free.

**How it works:** When a Glue job inside the private subnet sends a request to `s3.amazonaws.com`, AWS intercepts that traffic and routes it through the VPC endpoint directly to S3 — never touching the public internet.

---

## Module Inputs (Variables)

| Variable | Type | Description |
|---|---|---|
| `environment` | string | The environment name: `dev`, `staging`, or `prod` |
| `vpc_cidr` | string | The IP address range for the VPC (e.g., `10.10.0.0/16`) |

These are defined in `variables.tf`.

---

## Module Outputs

| Output | Value | Used By |
|---|---|---|
| `vpc_id` | The VPC's unique AWS ID | `ingestion`, `processing`, `serving`, `orchestration` modules |
| `private_subnet_ids` | List of both private subnet IDs | All compute modules (Glue, MWAA, Redshift, DMS) |
| `public_subnet_id` | The public subnet's ID | Available for future use |

These are defined in `outputs.tf`. Other modules receive these values as inputs so they can deploy their resources into the same network.

---

## CIDR Subnetting — How the IP Ranges Are Calculated

The `cidrsubnet()` function divides the VPC CIDR into smaller subnets automatically.

For `10.10.0.0/16` with a `newbits` of `4`:

| Index | Subnet CIDR | Assigned To |
|---|---|---|
| 0 | `10.10.0.0/20` | Public Subnet |
| 1 | `10.10.16.0/20` | Private Subnet A |
| 2 | `10.10.32.0/20` | Private Subnet B |

Each `/20` subnet contains 4,096 IP addresses. There is room for additional subnets in the future.

---

## IP Ranges Across Environments

| Environment | VPC CIDR | Why Different |
|---|---|---|
| dev | `10.10.0.0/16` | Non-overlapping range for future peering |
| staging | `10.20.0.0/16` | Non-overlapping range for future peering |
| prod | `10.30.0.0/16` | Non-overlapping range for future peering |

Using non-overlapping ranges is a best practice. If you ever need to connect two accounts via VPC Peering (e.g., so prod can query dev metadata), overlapping CIDRs would make that impossible.

---

## How to Deploy This Module

This module is not deployed directly. It is called from an environment folder.

### Step 1 — Login to AWS

```bash
aws sso login --profile dev-admin
```

### Step 2 — Navigate to an environment

```bash
cd terraform-platform-infra-live/environments/dev
```

### Step 3 — Initialize Terraform

```bash
terraform init
```

This downloads the AWS provider and registers all modules. You only need to run this once (or after adding new modules).

### Step 4 — Preview what will be created

```bash
terraform plan
```

Terraform will show you a list of every resource it plans to create. Read this carefully before applying.

### Step 5 — Create the infrastructure

```bash
terraform apply
```

Type `yes` when prompted. Terraform creates all resources in AWS.

### Using the Makefile (shortcut)

From inside `terraform-platform-infra-live/`:

```bash
make init dev    # Same as: cd environments/dev && terraform init
make plan dev    # Same as: cd environments/dev && terraform plan
make apply dev   # Same as: cd environments/dev && terraform apply
```

---

## Validation — How to Confirm It Worked

After `terraform apply` completes, verify in the AWS Console:

1. **VPC Console** → VPCs → Find your VPC (filter by name `edp-dev`)
   - Check CIDR is `10.10.0.0/16`
   - DNS hostnames: Enabled
   - DNS resolution: Enabled

2. **VPC Console** → Subnets → Filter by VPC
   - 3 subnets should exist (1 public, 2 private)
   - Private subnets should be in different AZs

3. **VPC Console** → Route Tables
   - Public route table: Has a `0.0.0.0/0` route to the Internet Gateway
   - Private route table: Has NO `0.0.0.0/0` route

4. **VPC Console** → Endpoints
   - One S3 Gateway endpoint associated with the private route table

---

## What Comes Next

After networking is deployed, the next module to apply is **data-lake** (S3 medallion buckets).

Then **iam-metadata** (KMS key, IAM roles) — which uses the bucket names from `data-lake`.

Then all other modules which use `vpc_id` and `private_subnet_ids` from this module.

---

## Files in This Module

| File | Purpose |
|---|---|
| `main.tf` | All resource definitions (VPC, subnets, routes, endpoint) |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Values exported for other modules to consume |
