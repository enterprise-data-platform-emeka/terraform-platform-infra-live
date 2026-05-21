# -----------------------------------------------------------------------------
# Dev environment composition
# -----------------------------------------------------------------------------
# This file wires the reusable modules into one development stack. The order
# follows the platform dependency chain:
#   1. Network, data lake, and IAM metadata
#   2. Ingestion, processing, and serving
#   3. Default Step Functions orchestration
#   4. Optional validation and stakeholder entry points
#
# Dev is the fast iteration environment. Resources can be destroyed after each
# session, and optional services stay behind feature flags.

# -----------------------------------------------------------------------------
# 1. Foundation
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# 2. Data pipeline
# -----------------------------------------------------------------------------

module "ingestion" {
  count  = var.enable_cdc_simulator ? 1 : 0
  source = "../../modules/ingestion"

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
  db_name             = "ecommerce"
  db_username         = "postgres"
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
}

# -----------------------------------------------------------------------------
# 3. Orchestration
# -----------------------------------------------------------------------------

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
  force_destroy      = true

  glue_role_arn            = module.iam_metadata.glue_role_arn
  glue_scripts_bucket_name = module.data_lake.glue_scripts_bucket_name
  bronze_bucket_name       = module.data_lake.bronze_bucket_name
  athena_results_bucket    = module.data_lake.athena_results_bucket
}

# -----------------------------------------------------------------------------
# 4. Monitoring and stakeholder entry points
# -----------------------------------------------------------------------------

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

# Optional stakeholder entry point: custom HTML analytics dashboard.
# Streamlit remains available on port 8501. FastAPI remains available on port 80.
# This adds a separate ECS service exposed on the same ALB at port 3000.
module "analytics_web" {
  count  = var.enable_analytics_web ? 1 : 0
  source = "../../modules/analytics-web"

  environment           = var.environment
  name_prefix           = var.name_prefix
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  alb_arn               = module.analytics_agent[0].alb_arn
  alb_security_group_id = module.analytics_agent[0].alb_security_group_id
  analytics_agent_url   = "http://${module.analytics_agent[0].alb_dns_name}"
  desired_count         = var.analytics_web_desired_count
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

# Optional stakeholder entry point: Slack + MCP gateway.
# This is off by default so the current platform session remains unchanged.
# Enable with:
#   TF_VAR_enable_slack_mcp_gateway=true
#
# Slack workspace/app identity stays outside Terraform destroy. This module only
# manages the AWS runtime that connects to Slack via Socket Mode.
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

# -----------------------------------------------------------------------------
# 5. Optional dev-only bastion
# -----------------------------------------------------------------------------

# Bastion host for an SSM tunnel to private RDS.
# Commented out after Phase 1 CDC run. Uncomment when re-running the CDC simulator.
#
# Usage when uncommented (after apply):
#   aws ssm start-session \
#     --target <bastion_instance_id from output> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters 'host=<rds_endpoint>,portNumber=5432,localPortNumber=5433' \
#     --profile dev-admin
#
# data "aws_ami" "amazon_linux_2023" {
#   most_recent = true
#   owners      = ["amazon"]
#   filter {
#     name   = "name"
#     values = ["al2023-ami-*-x86_64"]
#   }
#   filter {
#     name   = "virtualization-type"
#     values = ["hvm"]
#   }
# }
#
# resource "aws_iam_role" "bastion_ssm" {
#   name = "${var.name_prefix}-${var.environment}-bastion-ssm-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
#   })
# }
#
# resource "aws_iam_role_policy_attachment" "bastion_ssm" {
#   role       = aws_iam_role.bastion_ssm.name
#   policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# }
#
# resource "aws_iam_instance_profile" "bastion" {
#   name = "${var.name_prefix}-${var.environment}-bastion-profile"
#   role = aws_iam_role.bastion_ssm.name
# }
#
# resource "aws_security_group" "bastion" {
#   name        = "${var.name_prefix}-${var.environment}-bastion-sg"
#   description = "Bastion for SSM tunnel to RDS, no inbound SSH required"
#   vpc_id      = module.networking.vpc_id
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
# }
#
# resource "aws_instance" "bastion" {
#   ami                         = data.aws_ami.amazon_linux_2023.id
#   instance_type               = "t3.micro"
#   subnet_id                   = module.networking.public_subnet_id
#   iam_instance_profile        = aws_iam_instance_profile.bastion.name
#   vpc_security_group_ids      = [aws_security_group.bastion.id]
#   user_data_replace_on_change = true
#   user_data = <<-EOF
#     #!/bin/bash
#     dnf install -y amazon-ssm-agent
#     systemctl enable amazon-ssm-agent
#     systemctl start amazon-ssm-agent
#     systemctl restart amazon-ssm-agent
#     EOF
#   depends_on = [aws_iam_role_policy_attachment.bastion_ssm, aws_iam_instance_profile.bastion]
#   tags = { Name = "${var.name_prefix}-${var.environment}-bastion", Purpose = "SSM tunnel to RDS" }
# }
#
# resource "aws_security_group_rule" "rds_ingress_bastion" {
#   type                     = "ingress"
#   from_port                = 5432
#   to_port                  = 5432
#   protocol                 = "tcp"
#   source_security_group_id = aws_security_group.bastion.id
#   security_group_id        = module.ingestion.rds_security_group_id
#   description              = "Allow bastion SSM tunnel to reach RDS"
# }
