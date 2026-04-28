output "mwaa_environment_name" {
  description = "MWAA environment name"
  value       = aws_mwaa_environment.this.name
}

output "mwaa_webserver_url" {
  description = "URL for the Airflow web UI. Open this in a browser to see DAGs, trigger runs, and view logs."
  value       = aws_mwaa_environment.this.webserver_url
}

output "dags_bucket_name" {
  description = "Name of the S3 bucket where Airflow DAG Python files are uploaded"
  value       = aws_s3_bucket.dags.id
}

output "dags_bucket_arn" {
  description = "ARN of the DAGs S3 bucket"
  value       = aws_s3_bucket.dags.arn
}

output "mwaa_security_group_id" {
  description = "Security group ID for the MWAA environment"
  value       = aws_security_group.mwaa.id
}

output "run_dbt_job_name" {
  description = "Name of the run_dbt Glue Python Shell job — referenced by the MWAA DAG gold_dbt_run task"
  value       = aws_glue_job.run_dbt.name
}
