# Values without a default must be supplied. alert_email deliberately has no
# default: it is personal data and this repository is public, so it is passed
# via TF_VAR_alert_email by scripts/lib.sh at apply time.

variable "project_name" {
  description = "Project slug. Also the value of the Project cost allocation tag."
  type        = string
  default     = "ce-capstone"
}

variable "environment" {
  description = "Environment name. Combined with project_name to prefix every resource."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "Region the environment is deployed into."
  type        = string
  default     = "us-east-1"
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

variable "alert_email" {
  description = "Address subscribed to the alert topic. Supplied at apply time, never committed."
  type        = string
}

# --- Network ----------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Availability zones to span. Two is the minimum for high availability."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Share one NAT Gateway across AZs. A deliberate cost trade-off; see docs/decisions/0002-single-nat-gateway.md."
  type        = bool
  default     = true
}

# --- Application ------------------------------------------------------------

variable "app_port" {
  description = "TCP port the application listens on."
  type        = number
  default     = 3000
}

variable "instance_type" {
  description = "EC2 instance type for the application tier."
  type        = string
  default     = "t4g.micro"
}

variable "instance_architecture" {
  description = "AMI architecture. Must match instance_type: arm64 for t4g, x86_64 for t3."
  type        = string
  default     = "arm64"
}

variable "min_size" {
  description = "Minimum instances. Three is the floor set by the project requirements."
  type        = number
  default     = 3
}

variable "max_size" {
  description = "Maximum instances the scaling policy may add, and the ceiling on compute spend."
  type        = number
  default     = 6
}

variable "desired_capacity" {
  description = "Instance count at steady state."
  type        = number
  default     = 3
}

variable "cpu_target_utilization" {
  description = "Average CPU percentage the target tracking policy holds the fleet at."
  type        = number
  default     = 50
}

# --- Data ---------------------------------------------------------------------

variable "enable_point_in_time_recovery" {
  description = "DynamoDB continuous backup, giving a 35-day restore window at roughly a 5 minute RPO."
  type        = bool
  default     = true
}

variable "enable_backup_plan" {
  description = "Create the AWS Backup vault, plan and selection covering the catalog table."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "How long scheduled recovery points are kept."
  type        = number
  default     = 7
}

variable "enable_deletion_protection" {
  description = "Block deletion of the load balancer and catalog table. On in prod. Blocks accidental destruction of the load balancer and catalog table."
  type        = bool
  default     = false
}

# --- Observability ------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for application and VPC flow logs."
  type        = number
  default     = 7
}

variable "metrics_namespace" {
  description = "CloudWatch namespace for custom metrics published by the agent."
  type        = string
  default     = "CeCapstone"
}

variable "enable_detailed_monitoring" {
  description = "One-minute EC2 metrics. Roughly USD 2.10 per instance per month; on in prod for 1-minute granularity."
  type        = bool
  default     = false
}

variable "cpu_alarm_threshold" {
  description = "Fleet CPU percentage that signals scaling is not keeping up. Must sit above cpu_target_utilization."
  type        = number
  default     = 80
}

variable "latency_p95_threshold_seconds" {
  description = "95th percentile response time budget, in seconds."
  type        = number
  default     = 1.0
}

# --- Cost ---------------------------------------------------------------------

variable "enable_budget_alert" {
  description = "Create the monthly cost budget and its notifications."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly spend ceiling for this project. Notifications fire at 80% actual and 100% forecast."
  type        = number
  default     = 40
}
