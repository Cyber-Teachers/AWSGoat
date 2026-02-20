# Bootstrap Terraform: creates the S3 bucket used by module-1 and module-2 for remote state.
# Run this once per AWS account (e.g. in CI before bulk apply).
# See: https://developer.hashicorp.com/terraform/language/state/remote

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "do-not-delete-awsgoat-state-files-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tf_state" {
  bucket        = local.bucket_name
  force_destroy = false
  tags = {
    Name    = "AWSGoat Terraform State"
    Project = "AWSGoat"
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Optional: block public access (recommended for state bucket)
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  value       = aws_s3_bucket.tf_state.id
  description = "S3 bucket name for Terraform state (use in -backend-config bucket=...)"
}
