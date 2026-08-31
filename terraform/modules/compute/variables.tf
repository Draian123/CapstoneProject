variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. ce-capstone-dev."
  type        = string
}

variable "environment" {
  description = "Environment name, surfaced by the application and used in log context."
  type        = string
}

variable "tags" {
  description = "Cost allocation tags propagated to ASG instances and volumes, which provider default_tags cannot reach."
  type        = map(string)
  default     = {}
}

# --- Networking inputs (from the networking module) -------------------------

variable "vpc_id" {
  description = "VPC hosting the load balancer and instances."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer. At least two, in different AZs."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An Application Load Balancer requires subnets in at least two availability zones."
  }
}

variable "private_subnet_ids" {
  description = "Private subnets the Auto Scaling group launches instances into."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnets are required for a multi-AZ application tier."
  }
}

variable "alb_security_group_id" {
  description = "Security group for the load balancer."
  type        = string
}

variable "app_security_group_id" {
  description = "Security group for the application instances."
  type        = string
}

# --- Data tier inputs (from the data module) --------------------------------

variable "products_table_name" {
  description = "DynamoDB catalog table name, passed to the application as PRODUCTS_TABLE."
  type        = string
}

variable "products_table_arn" {
  description = "DynamoDB catalog table ARN, used to scope the instance role to that one table."
  type        = string
}

# --- Application ------------------------------------------------------------

variable "app_source_path" {
  description = "Path to the application entrypoint, embedded into instance user-data at apply time."
  type        = string
}

variable "app_port" {
  description = "TCP port the application listens on."
  type        = number
  default     = 3000
}

variable "health_check_path" {
  description = "Path the load balancer polls to decide whether a target is in service."
  type        = string
  default     = "/health"
}

# --- Capacity ---------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. Graviton (t4g) is roughly 20% cheaper than the equivalent x86 t3."
  type        = string
  default     = "t4g.micro"
}

variable "instance_architecture" {
  description = "AMI architecture, which must match instance_type. Use arm64 for t4g, x86_64 for t3."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be arm64 or x86_64."
  }
}

variable "min_size" {
  description = "Minimum instances. Three is the floor set by the project requirements."
  type        = number
  default     = 3

  validation {
    condition     = var.min_size >= 3
    error_message = "The platform requires at least three application instances spread across availability zones."
  }
}

variable "max_size" {
  description = "Maximum instances the scaling policy may add. Also the ceiling on compute spend."
  type        = number
  default     = 6
}

variable "desired_capacity" {
  description = "Instance count at steady state."
  type        = number
  default     = 3
}

variable "cpu_target_utilization" {
  description = "Average CPU percentage the target tracking policy holds the group at."
  type        = number
  default     = 50
}

variable "health_check_grace_period" {
  description = "Seconds an instance has to finish bootstrapping before health checks count against it."
  type        = number
  default     = 180
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size. The runtime and application need only a few GB."
  type        = number
  default     = 10
}

# --- Operational toggles ----------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for application logs."
  type        = number
  default     = 7
}

variable "metrics_namespace" {
  description = "CloudWatch namespace for custom metrics published by the agent."
  type        = string
  default     = "CeCapstone"
}

variable "enable_detailed_monitoring" {
  description = "One-minute EC2 metrics. Costs roughly USD 2.10 per instance per month; off by default."
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Block load balancer deletion. Left off in dev so the teardown script can destroy the environment."
  type        = bool
  default     = false
}
