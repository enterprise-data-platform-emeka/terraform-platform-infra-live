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

module "iam_metadata" {
  source                 = "../../modules/iam-metadata"
  environment            = var.environment
  name_prefix            = var.name_prefix
  bronze_bucket_name     = module.data_lake.bronze_bucket_name
  silver_bucket_name     = module.data_lake.silver_bucket_name
  gold_bucket_name       = module.data_lake.gold_bucket_name
  quarantine_bucket_name = module.data_lake.quarantine_bucket_name
}

module "ingestion" {
  source              = "../../modules/ingestion"
  environment         = var.environment
  name_prefix         = var.name_prefix
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  kms_key_arn         = module.iam_metadata.kms_key_arn
  bronze_bucket_name  = module.data_lake.bronze_bucket_name
  dms_s3_role_arn     = module.iam_metadata.dms_s3_role_arn
  db_password         = var.db_password
  db_instance_class   = var.db_instance_class
  dms_instance_class  = var.dms_instance_class
  multi_az            = var.multi_az
  deletion_protection = var.deletion_protection
}