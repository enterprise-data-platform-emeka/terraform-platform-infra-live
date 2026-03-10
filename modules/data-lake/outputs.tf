output "bronze_bucket_name" {
  value = aws_s3_bucket.this["bronze"].bucket
}

output "silver_bucket_name" {
  value = aws_s3_bucket.this["silver"].bucket
}

output "gold_bucket_name" {
  value = aws_s3_bucket.this["gold"].bucket
}

output "quarantine_bucket_name" {
  value = aws_s3_bucket.this["quarantine"].bucket
}

output "athena_results_bucket" {
  value = aws_s3_bucket.this["athena_results"].bucket
}
