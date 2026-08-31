output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state. Referenced by every environment backend.tf."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_region" {
  description = "Region of the remote state bucket."
  value       = var.aws_region
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "gha_plan_role_arn" {
  description = "Role ARN for the plan workflow. Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.gha_plan.arn
}

output "gha_apply_role_arn" {
  description = "Role ARN for the apply workflow. Set as the AWS_APPLY_ROLE_ARN repository variable."
  value       = aws_iam_role.gha_apply.arn
}
