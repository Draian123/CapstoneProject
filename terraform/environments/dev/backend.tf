# Remote state.
#
# Values are supplied by scripts/lib.sh at init time rather than hardcoded,
# because the bucket name embeds the AWS account ID:
#
#   terraform init -backend-config="bucket=..." -backend-config="key=..."
#
# Keeping the block partial is what lets this repository be applied in any
# account without editing tracked files.
#
# Locking uses the S3 native lock file (Terraform 1.10+), which removes the
# DynamoDB lock table the older pattern required -- one less resource to
# create, pay for and forget to destroy.
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
