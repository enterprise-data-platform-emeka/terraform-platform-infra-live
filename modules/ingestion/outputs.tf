output "rds_endpoint" {
  value = aws_db_instance.source.address
}

output "rds_port" {
  value = aws_db_instance.source.port
}

output "rds_identifier" {
  value = aws_db_instance.source.identifier
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "dms_security_group_id" {
  value = aws_security_group.dms.id
}

output "dms_replication_instance_arn" {
  value = aws_dms_replication_instance.this.replication_instance_arn
}

output "dms_replication_task_arn" {
  value = aws_dms_replication_task.cdc.replication_task_arn
}

output "ssm_db_password_path" {
  description = "SSM parameter path for the RDS password — fetch with: aws ssm get-parameter --name <value> --with-decryption"
  value       = aws_ssm_parameter.db_password.name
}
