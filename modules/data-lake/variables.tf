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