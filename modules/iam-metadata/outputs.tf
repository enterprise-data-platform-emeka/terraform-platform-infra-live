output "kms_key_arn" {
  value = aws_kms_key.platform.arn
}

output "kms_key_id" {
  value = aws_kms_key.platform.key_id
}

output "glue_role_arn" {
  value = aws_iam_role.glue.arn
}

output "mwaa_role_arn" {
  value = aws_iam_role.mwaa.arn
}

output "redshift_role_arn" {
  value = aws_iam_role.redshift.arn
}

output "dms_s3_role_arn" {
  value = aws_iam_role.dms_s3.arn
}

output "glue_catalog_database_bronze" {
  value = aws_glue_catalog_database.bronze.name
}

output "glue_catalog_database_silver" {
  value = aws_glue_catalog_database.silver.name
}

output "glue_catalog_database_gold" {
  value = aws_glue_catalog_database.gold.name
}
