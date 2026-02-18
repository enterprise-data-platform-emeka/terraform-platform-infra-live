######################################################
# VPC ID Output
######################################################

output "vpc_id" {
  value = aws_vpc.this.id
}



######################################################
# Private Subnet IDs
######################################################

output "private_subnet_ids" {
  value = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]
}



######################################################
# Public Subnet ID
######################################################

output "public_subnet_id" {
  value = aws_subnet.public.id
}
