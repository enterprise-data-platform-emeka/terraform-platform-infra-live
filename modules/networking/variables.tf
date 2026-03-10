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