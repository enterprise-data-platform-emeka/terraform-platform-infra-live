# -----------------------------------------------------------------------------
# Data lake input variables
# -----------------------------------------------------------------------------
# Receives environment naming and teardown behavior for S3 bucket creation.

variable "environment" {
  type = string
}

variable "force_destroy" {
  type    = bool
  default = false
}

variable "name_prefix" {
  description = "Global naming prefix"
  type        = string
}
