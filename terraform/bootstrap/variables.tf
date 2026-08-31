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
