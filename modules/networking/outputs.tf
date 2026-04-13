output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id, aws_subnet.public_b.id]
}

output "nat_gateway_id" {
  description = "NAT Gateway ID, or empty string if create_nat_gateway is false. Pass to modules that must wait for NAT routing to be ready before creating resources."
  value       = var.create_nat_gateway ? aws_nat_gateway.this[0].id : ""
}