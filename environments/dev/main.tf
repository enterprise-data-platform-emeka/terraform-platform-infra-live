module "networking" {
  source      = "../../modules/networking"
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}

module "data_lake" {
  source        = "../../modules/data-lake"
  environment   = var.environment
  force_destroy = true
  name_prefix   = var.name_prefix
}