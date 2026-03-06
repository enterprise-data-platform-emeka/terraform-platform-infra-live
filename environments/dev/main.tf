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
}

module "serving" {
  source                  = "../../modules/serving"
  environment             = var.environment
  name_prefix             = var.name_prefix
  vpc_id                  = module.networking.vpc_id
  vpc_cidr                = var.vpc_cidr
  private_subnet_ids      = module.networking.private_subnet_ids
  kms_key_arn             = module.iam_metadata.kms_key_arn
  redshift_role_arn       = module.iam_metadata.redshift_role_arn
  redshift_admin_password = var.redshift_admin_password
}

# module "orchestration" {
#   source             = "../../modules/orchestration"
#   environment        = var.environment
#   name_prefix        = var.name_prefix
#   vpc_id             = module.networking.vpc_id
#   private_subnet_ids = module.networking.private_subnet_ids
#   kms_key_arn        = module.iam_metadata.kms_key_arn
#   mwaa_role_arn      = module.iam_metadata.mwaa_role_arn
#   force_destroy      = true
# }

######################################################
# Bastion host — SSM tunnel to private RDS
#
# RDS lives in private subnets with no internet route.
# This EC2 instance sits in the public subnet and lets
# us reach RDS from a Mac via SSM port-forwarding —
# no SSH key or open port 5432 needed.
#
# Usage after apply:
#   aws ssm start-session \
#     --target <bastion_instance_id from output> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters 'host=<rds_endpoint>,portNumber=5432,localPortNumber=5433' \
#     --profile dev-admin
#
# Then set DB_HOST=localhost DB_PORT=5433 in .env and run make schema/seed/simulate.
# Destroy after testing: make destroy dev
######################################################

# AMI — Amazon Linux 2023 (SSM agent pre-installed, no extra setup needed)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM role — grants the bastion permission to register with SSM
resource "aws_iam_role" "bastion_ssm" {
  name = "${var.name_prefix}-${var.environment}-bastion-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name_prefix}-${var.environment}-bastion-profile"
  role = aws_iam_role.bastion_ssm.name
}

# Security group — no inbound rules (SSM does not need port 22 open)
resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-${var.environment}-bastion-sg"
  description = "Bastion for SSM tunnel to RDS — no inbound SSH required"
  vpc_id      = module.networking.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound so the SSM agent can reach AWS endpoints"
  }

  tags = {
    Name        = "${var.name_prefix}-${var.environment}-bastion-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# EC2 bastion — t3.micro in the public subnet
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.networking.public_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  tags = {
    Name        = "${var.name_prefix}-${var.environment}-bastion"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "SSM tunnel to RDS for simulator — destroy after testing"
  }
}

# Allow the bastion to reach RDS on port 5432
# (The RDS SG normally only allows DMS — this adds the bastion as an extra source)
resource "aws_security_group_rule" "rds_ingress_bastion" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = module.ingestion.rds_security_group_id
  description              = "Allow bastion SSM tunnel to reach RDS"
}
