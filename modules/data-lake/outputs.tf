######################################################
# Bucket Outputs for Downstream Modules
######################################################

output "bronze_bucket_name" {
  value = aws_s3_bucket.bronze.bucket
}

output "silver_bucket_name" {
  value = aws_s3_bucket.silver.bucket
}

output "gold_bucket_name" {
  value = aws_s3_bucket.gold.bucket
}

output "quarantine_bucket_name" {
  value = aws_s3_bucket.quarantine.bucket
}

output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}