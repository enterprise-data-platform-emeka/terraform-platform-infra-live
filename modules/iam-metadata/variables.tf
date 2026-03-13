variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "name_prefix" {
  description = "Global naming prefix"
  type        = string
}

variable "bronze_bucket_name" {
  description = "Name of the Bronze S3 bucket"
  type        = string
}

variable "silver_bucket_name" {
  description = "Name of the Silver S3 bucket"
  type        = string
}

variable "gold_bucket_name" {
  description = "Name of the Gold S3 bucket"
  type        = string
}

variable "quarantine_bucket_name" {
  description = "Name of the Quarantine S3 bucket"
  type        = string
}

variable "glue_scripts_bucket_name" {
  description = "Name of the Glue scripts S3 bucket"
  type        = string
}

# ── GitHub Actions OIDC ──────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organisation or username that owns the repositories (e.g. acme-corp)"
  type        = string
}

variable "github_repos" {
  description = "GitHub repository names allowed to assume the GitHub Actions IAM role"
  type        = list(string)
  default     = ["terraform-platform-infra-live", "platform-glue-jobs", "platform-dbt-analytics"]
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider in this AWS account. The provider is account-scoped, not region-scoped. If dev, staging, and prod share the same AWS account, set this to true only for the first environment and false for the rest."
  type        = bool
  default     = true
}
