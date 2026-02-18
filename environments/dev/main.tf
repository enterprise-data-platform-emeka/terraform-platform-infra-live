######################################################
# Networking Module Composition
######################################################

module "networking" {
  source      = "../../modules/networking"
  environment = "dev"
  vpc_cidr    = "10.10.0.0/16"
  region      = "eu-central-1"
}
