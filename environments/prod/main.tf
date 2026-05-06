module "networking" {
  source             = "../../modules/networking"
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  create_nat_gateway = true
}

module "data_lake" {
  source        = "../../modules/data-lake"
  environment   = var.environment
  force_destroy = false
  name_prefix   = var.name_prefix
}

module "iam_metadata" {
  source                     = "../../modules/iam-metadata"
  environment                = var.environment
  name_prefix                = var.name_prefix
  bronze_bucket_name         = module.data_lake.bronze_bucket_name
  silver_bucket_name         = module.data_lake.silver_bucket_name
  gold_bucket_name           = module.data_lake.gold_bucket_name
  quarantine_bucket_name     = module.data_lake.quarantine_bucket_name
  glue_scripts_bucket_name   = module.data_lake.glue_scripts_bucket_name
  athena_results_bucket_name = module.data_lake.athena_results_bucket
}

module "ingestion" {
  count  = var.enable_cdc_simulator ? 1 : 0
  source = "../../modules/ingestion"

  environment        = var.environment
  name_prefix        = var.name_prefix
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  kms_key_arn        = module.iam_metadata.kms_key_arn
  bronze_bucket_name = module.data_lake.bronze_bucket_name
  dms_s3_role_arn    = module.iam_metadata.dms_s3_role_arn

  db_password             = var.db_password
  db_name                 = "ecommerce"
  db_username             = "postgres"
  db_instance_class       = var.db_instance_class
  dms_instance_class      = var.dms_instance_class
  multi_az                = var.multi_az
  deletion_protection     = var.deletion_protection
  backup_retention_period = 30
}

module "processing" {
  source                = "../../modules/processing"
  environment           = var.environment
  name_prefix           = var.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  kms_key_arn           = module.iam_metadata.kms_key_arn
  athena_results_bucket = module.data_lake.athena_results_bucket
  silver_bucket_name    = module.data_lake.silver_bucket_name
}

module "serving" {
  count  = var.enable_serving ? 1 : 0
  source = "../../modules/serving"

  environment             = var.environment
  name_prefix             = var.name_prefix
  vpc_id                  = module.networking.vpc_id
  vpc_cidr                = var.vpc_cidr
  private_subnet_ids      = module.networking.private_subnet_ids
  kms_key_arn             = module.iam_metadata.kms_key_arn
  redshift_role_arn       = module.iam_metadata.redshift_role_arn
  redshift_admin_password = var.redshift_admin_password
  base_capacity_rpus      = var.redshift_base_capacity_rpus
}

module "step_functions" {
  count  = var.enable_step_functions ? 1 : 0
  source = "../../modules/step-functions"

  environment              = var.environment
  name_prefix              = var.name_prefix
  bronze_bucket_name       = module.data_lake.bronze_bucket_name
  athena_results_bucket    = module.data_lake.athena_results_bucket
  glue_scripts_bucket_name = module.data_lake.glue_scripts_bucket_name
  kms_key_arn              = module.iam_metadata.kms_key_arn
  glue_role_arn            = module.iam_metadata.glue_role_arn
}

module "orchestration" {
  count  = var.enable_mwaa ? 1 : 0
  source = "../../modules/orchestration"

  environment        = var.environment
  name_prefix        = var.name_prefix
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  kms_key_arn        = module.iam_metadata.kms_key_arn
  mwaa_role_arn      = module.iam_metadata.mwaa_role_arn
  nat_gateway_id     = module.networking.nat_gateway_id
  force_destroy      = false

  glue_role_arn            = module.iam_metadata.glue_role_arn
  glue_scripts_bucket_name = module.data_lake.glue_scripts_bucket_name
  bronze_bucket_name       = module.data_lake.bronze_bucket_name
  athena_results_bucket    = module.data_lake.athena_results_bucket
}

module "source_simulator_runtime" {
  count  = var.enable_cdc_simulator ? 1 : 0
  source = "../../modules/source-simulator-runtime"

  environment           = var.environment
  name_prefix           = var.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  rds_security_group_id = module.ingestion[0].rds_security_group_id
  rds_endpoint          = module.ingestion[0].rds_endpoint
  ssm_db_password_path  = module.ingestion[0].ssm_db_password_path
  kms_key_arn           = module.iam_metadata.kms_key_arn
}

module "analytics_agent" {
  count  = var.enable_analytics_agent ? 1 : 0
  source = "../../modules/analytics-agent"

  environment           = var.environment
  name_prefix           = var.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  public_subnet_ids     = module.networking.public_subnet_ids
  bronze_bucket_name    = module.data_lake.bronze_bucket_name
  silver_bucket_name    = module.data_lake.silver_bucket_name
  gold_bucket_name      = module.data_lake.gold_bucket_name
  athena_results_bucket = module.data_lake.athena_results_bucket
  kms_key_arn           = module.iam_metadata.kms_key_arn
  glue_gold_database    = module.iam_metadata.glue_catalog_database_gold
  glue_silver_database  = module.iam_metadata.glue_catalog_database_silver
}

module "monitoring" {
  count  = var.enable_step_functions && var.enable_analytics_agent ? 1 : 0
  source = "../../modules/monitoring"

  environment        = var.environment
  name_prefix        = var.name_prefix
  alert_email        = var.alert_email
  state_machine_name = module.step_functions[0].state_machine_name
  ecs_cluster_name   = module.analytics_agent[0].ecs_cluster_name
  ecs_service_name   = module.analytics_agent[0].ecs_service_name
  alb_arn_suffix     = module.analytics_agent[0].alb_arn_suffix
}

module "slack_mcp_gateway" {
  count  = var.enable_slack_mcp_gateway ? 1 : 0
  source = "../../modules/slack-mcp-gateway"

  environment         = var.environment
  name_prefix         = var.name_prefix
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  analytics_agent_url = "http://${module.analytics_agent[0].alb_dns_name}"
  allowed_channels    = var.slack_mcp_allowed_channels
  desired_count       = var.slack_mcp_desired_count
}
