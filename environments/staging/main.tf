######################################################
# Networking Module Composition
######################################################

module "networking" {
  source      = "../../modules/networking"
  environment = "staging"
  vpc_cidr    = "10.10.0.0/16"
  region      = "eu-central-1"
}

######################################################
# Data Lake Module Composition
######################################################

module "data_lake" {
  source        = "../../modules/data-lake"
  environment   = "staging"
  force_destroy = true
}
