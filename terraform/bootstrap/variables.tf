variable "aws_region" {
  description = "AWS region hosting the remote state bucket and CI roles."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project slug used to name shared resources."
  type        = string
  default     = "ce-capstone"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
  default     = "Draian123"
}

variable "github_repo" {
  description = "GitHub repository name allowed to assume the CI roles."
  type        = string
  default     = "CapstoneProject"
}

variable "alert_email" {
  description = <<-EOT
    Address subscribed to the shared alert topic.

    Supplied at apply time via TF_VAR_alert_email rather than committed, because
    this repository is public. AWS sends a confirmation email that must be
    clicked once before notifications deliver; because the topic lives in this
    layer rather than in an environment, that click is needed only once and not
    on every bring-up.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "enable_budget_alert" {
  description = "Create the project-wide monthly cost budget and its notifications."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly spend ceiling for the whole project. Notifications fire at 80% actual and 100% forecast."
  type        = number
  default     = 40

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "owner" {
  description = "Cost allocation tag: who owns this workload."
  type        = string
  default     = "dennis-beitel"
}

variable "cost_center" {
  description = "Cost allocation tag: which budget this workload bills to."
  type        = string
  default     = "ironhack-bootcamp"
}
