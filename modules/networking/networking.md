# Module: networking

**Location:** `terraform-platform-infra-live/modules/networking/`

---

## What this module does

This module creates the private network that all other platform services live inside.

Think of it like the roads, walls, and plumbing of a building before any furniture goes in. Nothing else in this platform can be deployed without networking existing first, because every AWS service needs a network to run in.

Specifically, this module creates:

1. A **VPC (Virtual Private Cloud)** - a private, isolated network in AWS that is completely separate from the internet and from other AWS accounts
2. An **Internet Gateway (IGW)** - the door between the public subnet and the internet
3. One **public subnet** - a network segment inside the VPC that has a route to the internet, reserved for future use like a bastion host (a jump server used to access private resources)
4. Two **private subnets** across two AZs (Availability Zones, which are independent data centers within the same AWS region) - where all compute services actually run
5. **Route tables** - the traffic rules that define where network packets go
6. An **S3 (Simple Storage Service) Gateway VPC Endpoint** - a direct connection that lets private subnets reach S3 without going through the internet

---

## Why this exists

AWS services need a network boundary to operate in. Without a VPC:
- Services have no isolation from each other or the internet
- There is no way to control inbound or outbound traffic
- Services cannot communicate privately with each other
- There is no private access to S3, which would require an expensive NAT (Network Address Translation) Gateway instead

This module provides all of that in one reusable block.

---

## Resources created

### 1. `aws_vpc` - The private network

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}
```

A VPC is like a private data center network inside AWS. Only resources I explicitly place inside it can communicate with each other.

`cidr_block` defines the IP address range for the entire network. For dev this is `10.10.0.0/16`, which gives 65,536 available IP addresses. CIDR (Classless Inter-Domain Routing) is the notation used to define these ranges.

`enable_dns_hostnames = true` is required because managed services like Glue and Redshift need to resolve each other's DNS (Domain Name System) hostnames, for example `my-rds-instance.abc.eu-central-1.rds.amazonaws.com`. Without this, internal name resolution does not work.

---

### 2. `aws_internet_gateway` - The internet door

```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}
```

The Internet Gateway (IGW) allows outbound traffic from the public subnet to reach the internet, and allows inbound traffic from the internet to reach the public subnet.

The private subnets are not connected to this gateway. They have no route to the internet by design. This keeps all compute services isolated from direct internet access.

---

### 3. `aws_subnet.public` - The public subnet

```hcl
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}
```

A subnet is a smaller network segment carved out of the VPC's CIDR range.

`cidrsubnet(var.vpc_cidr, 4, 0)` automatically calculates the subnet IP range from the VPC's CIDR. For `10.10.0.0/16` with a `/4` prefix extension, this gives `10.10.0.0/20`.

This subnet is reserved for future use (a bastion host or load balancer). No data processing happens here. All compute lives in the private subnets.

---

### 4. `aws_subnet.private_a` and `aws_subnet.private_b` - The compute subnets

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

These are the two subnets where all actual compute services run: AWS Glue jobs, Amazon Redshift Serverless, Amazon MWAA (Managed Workflows for Apache Airflow), AWS DMS (Database Migration Service) replication instances, and Amazon RDS (Relational Database Service).

I create two subnets across two AZs (Availability Zones) because AWS requires services like MWAA and Redshift Serverless to span at least two AZs. An AZ is an independent data center within the same AWS region. If one AZ has an outage, the service continues running in the other AZ. This is called high availability.

These subnets have no route to the internet. This means external traffic cannot reach these services directly, and services cannot accidentally send data out to the internet. The only way to reach S3 is through the VPC Endpoint described below.

---

### 5. Route tables - Traffic rules

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
  # No routes - traffic stays inside the VPC only
}
```

Route tables are like GPS rules for network traffic. When a packet arrives, AWS looks up the route table to decide where to send it.

The public route table has one rule: send all traffic (`0.0.0.0/0` means "everything") to the Internet Gateway.

The private route table has no external routes. Traffic from private subnets can only reach other resources inside the VPC, or S3 via the endpoint below.

`aws_route_table_association` links each route table to its subnet. A subnet without an explicit association falls back to the VPC's default route table.

---

### 6. `aws_vpc_endpoint.s3` - The S3 express lane

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
```

An S3 Gateway VPC Endpoint is a direct connection that allows private subnets to reach Amazon S3 without going through the internet.

This matters because Glue jobs read and write large amounts of data to S3. Without this endpoint, that traffic would need a NAT (Network Address Translation) Gateway, which costs approximately $32 per month per AZ plus data processing fees. The S3 Gateway Endpoint is free.

When a Glue job inside the private subnet sends a request to `s3.amazonaws.com`, AWS intercepts it and routes it through the VPC endpoint directly to S3, never touching the public internet.

---

## Why no NAT Gateway?

NAT (Network Address Translation) allows private subnets to access the public internet. I intentionally do not include a NAT Gateway in this module because:

- The only external service my compute jobs need to reach is S3
- The S3 Gateway VPC Endpoint covers that requirement for free
- Adding a NAT Gateway would cost roughly $32 per month with no benefit

If the AI Operations Agent (which runs as an ECS Fargate task and needs to reach the Anthropic Claude API) requires internet access, I add a NAT Gateway in the orchestration module or configure the ECS task to use a public subnet.

---

## How subnets are calculated

The `cidrsubnet()` function divides the VPC CIDR into smaller subnets automatically.

For `10.10.0.0/16` with a `newbits` of `4`:

| Index | Subnet CIDR | Assigned to |
|---|---|---|
| 0 | `10.10.0.0/20` | Public Subnet |
| 1 | `10.10.16.0/20` | Private Subnet A |
| 2 | `10.10.32.0/20` | Private Subnet B |

Each `/20` subnet contains 4,096 IP addresses. The remaining space in the VPC (`10.10.48.0` onwards) is available for future subnets.

---

## IP ranges across environments

| Environment | VPC CIDR | Why different |
|---|---|---|
| dev | `10.10.0.0/16` | Non-overlapping for future VPC peering |
| staging | `10.20.0.0/16` | Non-overlapping for future VPC peering |
| prod | `10.30.0.0/16` | Non-overlapping for future VPC peering |

Using non-overlapping CIDR ranges is a best practice. If I ever need to connect two accounts via VPC Peering (so one account can access resources in another), overlapping CIDRs make that impossible.

---

## Module inputs (variables)

| Variable | Type | Description |
|---|---|---|
| `environment` | string | The environment name: `dev`, `staging`, or `prod` |
| `vpc_cidr` | string | The IP address range for the VPC, for example `10.10.0.0/16` |

---

## Module outputs

| Output | Value | Used by |
|---|---|---|
| `vpc_id` | The VPC's unique AWS ID | `ingestion`, `processing`, `serving`, `orchestration` modules |
| `private_subnet_ids` | List of both private subnet IDs | All compute modules (Glue, MWAA, Redshift, DMS) |
| `public_subnet_id` | The public subnet's ID | Available for future use |

Other modules receive these values as inputs so they can deploy their resources into the same network.

---

## How to deploy

This module is not deployed directly. It is called from an environment folder.

```bash
# Log in to AWS
aws sso login --profile dev-admin

# Navigate to the environment
cd terraform-platform-infra-live/environments/dev

# Initialize Terraform (run once, or after adding new modules)
terraform init

# Preview what will be created
terraform plan

# Create the infrastructure
terraform apply
```

Or using the Makefile shortcut from inside `terraform-platform-infra-live/`:

```bash
make init dev
make plan dev
make apply dev
```

---

## Validation checklist

After `terraform apply` completes, I check the following in the AWS console:

**VPC Console:**
- VPC exists with the correct CIDR
- DNS hostnames: Enabled
- DNS resolution: Enabled

**Subnets:**
- Three subnets exist: one public, two private
- Private subnets are in different AZs

**Route Tables:**
- Public route table has a `0.0.0.0/0` route to the Internet Gateway
- Private route table has no `0.0.0.0/0` route

**Endpoints:**
- One S3 Gateway Endpoint is associated with the private route table

---

## What comes next

After networking is deployed, the next module is `data-lake` (the five S3 buckets).

Then `iam-metadata` (the KMS key and IAM roles), which uses the bucket names from `data-lake`.

Then all other modules which use `vpc_id` and `private_subnet_ids` from this module.

---

## Files in this module

| File | Purpose |
|---|---|
| `main.tf` | All resource definitions: VPC, subnets, route tables, Internet Gateway, S3 endpoint |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Values exported for other modules to use |
