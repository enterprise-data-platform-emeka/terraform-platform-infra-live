output "namespace_name" {
  description = "Redshift Serverless namespace name"
  value       = aws_redshiftserverless_namespace.this.namespace_name
}

output "workgroup_name" {
  description = "Redshift Serverless workgroup name"
  value       = aws_redshiftserverless_workgroup.this.workgroup_name
}

output "workgroup_endpoint" {
  description = "Redshift Serverless endpoint hostname. BI tools and SQL clients connect to this."
  value       = aws_redshiftserverless_workgroup.this.endpoint[0].address
}

output "redshift_security_group_id" {
  description = "Security group ID for the Redshift workgroup"
  value       = aws_security_group.redshift.id
}

output "ssm_redshift_password_path" {
  description = "SSM parameter path for the Redshift admin password — fetch with: aws ssm get-parameter --name <value> --with-decryption"
  value       = aws_ssm_parameter.redshift_admin_password.name
}
