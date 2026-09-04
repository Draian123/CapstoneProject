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

variable "deploy_environments" {
  description = <<-EOT
    Environments the apply workflow may deploy to. Each is trusted as an OIDC
    subject on the apply role, because a job bound to a GitHub Environment
    presents `repo:owner/repo:environment:<name>` instead of a branch ref.

    Adding a name here lets any branch that environment's deployment-branch
    policy permits assume the apply role, so that policy in GitHub is the other
    half of this control.
  EOT
  type        = list(string)
  default     = ["dev", "prod"]
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

variable "github_owner_id" {
  description = <<-EOT
    Numeric GitHub account ID of github_owner.

    GitHub now issues OIDC subject claims that embed the numeric owner and
    repository IDs alongside their names, so the trust policy has to match on
    them. The IDs are immutable, which is the entire point: a claim naming only
    "Draian123/CapstoneProject" could be satisfied by deleting the repository
    and having someone else recreate it under the same name.

    Find it with: curl -s https://api.github.com/repos/OWNER/REPO | jq .owner.id
  EOT
  type        = number
  default     = 49660212
}

variable "github_repository_id" {
  description = <<-EOT
    Numeric GitHub repository ID of github_repo. See github_owner_id.

    Find it with: curl -s https://api.github.com/repos/OWNER/REPO | jq .id
  EOT
  type        = number
  default     = 1352118641
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
