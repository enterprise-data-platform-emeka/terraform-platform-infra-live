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
  source                   = "../../modules/iam-metadata"
  environment              = var.environment
  name_prefix              = var.name_prefix
  bronze_bucket_name       = module.data_lake.bronze_bucket_name
  silver_bucket_name       = module.data_lake.silver_bucket_name
  gold_bucket_name         = module.data_lake.gold_bucket_name
  quarantine_bucket_name   = module.data_lake.quarantine_bucket_name
  glue_scripts_bucket_name = module.data_lake.glue_scripts_bucket_name
}

# Ingestion (RDS + DMS) and bastion — commented out after Phase 1 CDC run.
# Bronze data is already in S3. Uncomment only when re-running the CDC simulator.
#
# module "ingestion" {
#   source              = "../../modules/ingestion"
#   environment         = var.environment
#   name_prefix         = var.name_prefix
#   vpc_id              = module.networking.vpc_id
#   private_subnet_ids  = module.networking.private_subnet_ids
#   kms_key_arn         = module.iam_metadata.kms_key_arn
#   bronze_bucket_name  = module.data_lake.bronze_bucket_name
#   dms_s3_role_arn     = module.iam_metadata.dms_s3_role_arn
#   db_password         = var.db_password
#   db_instance_class   = var.db_instance_class
#   dms_instance_class  = var.dms_instance_class
#   multi_az            = var.multi_az
#   deletion_protection = var.deletion_protection
#   db_name             = "ecommerce"
#   db_username         = "postgres"
# }

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

# module "serving" — disabled until Gold data exists.
# Redshift Serverless has a base RPU charge even when idle.
# Uncomment when platform-dbt-analytics Gold models are ready to load.
#
# module "serving" {
#   source                  = "../../modules/serving"
#   environment             = var.environment
#   name_prefix             = var.name_prefix
#   vpc_id                  = module.networking.vpc_id
#   vpc_cidr                = var.vpc_cidr
#   private_subnet_ids      = module.networking.private_subnet_ids
#   kms_key_arn             = module.iam_metadata.kms_key_arn
#   redshift_role_arn       = module.iam_metadata.redshift_role_arn
#   redshift_admin_password = var.redshift_admin_password
# }

# DEFAULT ORCHESTRATOR: Step Functions (fast startup, no separate deployment step)
# To switch to MWAA for the YouTube demo: comment out step_functions, uncomment orchestration below.
module "step_functions" {
  source = "../../modules/step-functions"

  environment              = var.environment
  name_prefix              = var.name_prefix
  bronze_bucket_name       = module.data_lake.bronze_bucket_name
  athena_results_bucket    = module.data_lake.athena_results_bucket
  glue_scripts_bucket_name = module.data_lake.glue_scripts_bucket_name
  kms_key_arn              = module.iam_metadata.kms_key_arn
}

# YOUTUBE DEMO ORCHESTRATOR: MWAA (full Airflow UI, ~25 min startup)
# Switch: comment out module "step_functions" above, uncomment this block.
# Also uncomment mwaa_role_arn output in outputs.tf if needed.
#
# module "orchestration" {
#   source             = "../../modules/orchestration"
#   environment        = var.environment
#   name_prefix        = var.name_prefix
#   vpc_id             = module.networking.vpc_id
#   private_subnet_ids = module.networking.private_subnet_ids
#   kms_key_arn        = module.iam_metadata.kms_key_arn
#   mwaa_role_arn      = module.iam_metadata.mwaa_role_arn
#   nat_gateway_id     = module.networking.nat_gateway_id
#   force_destroy      = true
# }

module "analytics_agent" {
  source = "../../modules/analytics-agent"

  environment        = var.environment
  name_prefix        = var.name_prefix
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  public_subnet_ids  = module.networking.public_subnet_ids
  bronze_bucket_name    = module.data_lake.bronze_bucket_name
  silver_bucket_name    = module.data_lake.silver_bucket_name
  gold_bucket_name      = module.data_lake.gold_bucket_name
  athena_results_bucket = module.data_lake.athena_results_bucket
  kms_key_arn           = module.iam_metadata.kms_key_arn
  glue_gold_database    = module.iam_metadata.glue_catalog_database_gold
  glue_silver_database  = module.iam_metadata.glue_catalog_database_silver
}

# Bastion host — SSM tunnel to private RDS.
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
