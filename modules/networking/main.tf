######################################################
# AWS VPC
######################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "edp-${var.environment}-vpc"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}



######################################################
# Internet Gateway (Public Internet Access)
######################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "edp-${var.environment}-igw"
    Environment = var.environment
  }
}



######################################################
# Public Subnet
######################################################

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "edp-${var.environment}-public-subnet"
    Environment = var.environment
  }
}



######################################################
# Private Subnet A
######################################################

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 1)
  availability_zone = "${var.region}a"

  tags = {
    Name        = "edp-${var.environment}-private-a"
    Environment = var.environment
  }
}



######################################################
# Private Subnet B
######################################################

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 2)
  availability_zone = "${var.region}b"

  tags = {
    Name        = "edp-${var.environment}-private-b"
    Environment = var.environment
  }
}



######################################################
# Public Route Table
######################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name        = "edp-${var.environment}-public-rt"
    Environment = var.environment
  }
}



######################################################
# Public Route Table Association
######################################################

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}



######################################################
# Private Route Table
######################################################

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "edp-${var.environment}-private-rt"
    Environment = var.environment
  }
}



######################################################
# Private Route Table Associations
######################################################

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}



######################################################
# S3 Gateway VPC Endpoint
######################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name        = "edp-${var.environment}-s3-endpoint"
    Environment = var.environment
  }
}
