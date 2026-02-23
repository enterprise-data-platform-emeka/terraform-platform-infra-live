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
