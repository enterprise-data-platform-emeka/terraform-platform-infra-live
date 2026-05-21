# -----------------------------------------------------------------------------
# IAM and metadata outputs
# -----------------------------------------------------------------------------
# Exposes role ARNs, KMS identifiers, and Glue database names to platform modules.

output "kms_key_arn" {
  description = "ARN of the shared platform KMS key used by services that read or write encrypted platform resources."
  value       = aws_kms_key.platform.arn
}

output "kms_key_id" {
  description = "ID of the shared platform KMS key."
  value       = aws_kms_key.platform.key_id
}

output "glue_role_arn" {
  description = "IAM role ARN assumed by Glue jobs for ETL, dbt helper work, catalog updates, and pipeline metrics."
  value       = aws_iam_role.glue.arn
}

output "mwaa_role_arn" {
  description = "IAM role ARN assumed by MWAA workers and schedulers to run the Airflow validation path."
  value       = aws_iam_role.mwaa.arn
}

output "redshift_role_arn" {
  description = "IAM role ARN assumed by Redshift Serverless to read external Silver and Gold data through Spectrum."
  value       = aws_iam_role.redshift.arn
}

output "dms_s3_role_arn" {
  description = "IAM role ARN assumed by DMS to write raw change data capture files into Bronze."
  value       = aws_iam_role.dms_s3.arn
}

output "glue_catalog_database_bronze" {
  description = "Glue Catalog database name for raw Bronze tables."
  value       = aws_glue_catalog_database.bronze.name
}

output "glue_catalog_database_silver" {
  description = "Glue Catalog database name for cleansed Silver tables."
  value       = aws_glue_catalog_database.silver.name
}

output "glue_catalog_database_gold" {
  description = "Glue Catalog database name for analytics-ready Gold tables."
  value       = aws_glue_catalog_database.gold.name
}
