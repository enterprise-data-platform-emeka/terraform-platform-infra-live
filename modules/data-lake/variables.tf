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
  description = "Allow bucket deletion even if non-empty (true only for dev)"
  type        = bool
  default     = false
}