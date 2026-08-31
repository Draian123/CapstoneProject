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

output "alerts_topic_arn" {
  description = "Shared SNS topic every environment publishes alarms to. Resolved by name in each environment."
  value       = aws_sns_topic.alerts.arn
}

output "alerts_topic_name" {
  description = "Name of the shared alert topic, used by the environments to look it up."
  value       = aws_sns_topic.alerts.name
}

output "budget_name" {
  description = "Project-wide monthly cost budget, or null when disabled."
  value       = var.enable_budget_alert ? aws_budgets_budget.project[0].name : null
}
