variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "name_prefix" {
  description = "Short prefix for all resource names (e.g. edp)"
  type        = string
  default     = "edp"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "create_nat_gateway" {
  description = "Whether to create a NAT Gateway so private subnets can reach the internet. Required for MWAA (to download PyPI packages). Costs ~$0.045/hr — only enable when MWAA is active."
  type        = bool
  default     = false
}