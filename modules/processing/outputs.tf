output "glue_security_configuration_name" {
  description = "Name of the Glue security configuration. Glue job definitions reference this by name to enable encryption."
  value       = aws_glue_security_configuration.this.name
}

output "glue_connection_name" {
  description = "Name of the Glue VPC network connection. Glue job definitions reference this by name to run inside the private subnets."
  value       = aws_glue_connection.vpc.name
}

output "glue_security_group_id" {
  description = "Security group ID for Glue jobs. The ingestion module can add a rule to allow Glue to reach RDS on port 5432."
  value       = aws_security_group.glue.id
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup. dbt and other query tools reference this when running SQL against the Glue catalog."
  value       = aws_athena_workgroup.this.name
}

output "silver_crawler_name" {
  description = "Name of the Glue Crawler that scans Silver S3 and registers table schemas in the Glue Data Catalog. The Airflow DAG triggers this after all Silver jobs complete."
  value       = aws_glue_crawler.silver.name
}
