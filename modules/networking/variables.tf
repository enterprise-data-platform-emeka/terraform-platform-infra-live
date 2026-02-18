######################################################
# Environment Identifier
######################################################

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}



######################################################
# VPC CIDR Block
######################################################

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}



######################################################
# AWS Region
######################################################

variable "region" {
  description = "AWS region"
  type        = string
}
