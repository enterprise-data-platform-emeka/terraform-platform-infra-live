######################################################
# Dev environment outputs
#
# After terraform apply, Terraform prints these values.
# Copy the ssm_tunnel_command output and run it in a
# separate terminal to open the RDS tunnel before running
# make schema / make seed / make simulate.
######################################################

output "rds_endpoint" {
  description = "RDS PostgreSQL hostname — used inside the SSM tunnel command"
  value       = module.ingestion.rds_endpoint
}

output "bastion_instance_id" {
  description = "EC2 bastion instance ID — used in the SSM tunnel command"
  value       = aws_instance.bastion.id
}

output "ssm_tunnel_command" {
  description = "Run this in a separate terminal to tunnel port 5433 on your Mac to RDS port 5432"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters 'host=${module.ingestion.rds_endpoint},portNumber=5432,localPortNumber=5433' --profile dev-admin"
}

output "simulator_env_block" {
  description = "Paste these lines into platform-cdc-simulator/.env to point the simulator at RDS"
  value       = <<-EOT
    DB_HOST=localhost
    DB_PORT=5433
    DB_NAME=ecommerce
    DB_USER=postgres
    DB_PASSWORD=<the password you set in TF_VAR_db_password>
  EOT
}
