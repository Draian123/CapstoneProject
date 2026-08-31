variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. ce-capstone-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough to carve az_count public and az_count private /24s."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, for example 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "Number of availability zones to span. Two is the minimum for the high-availability requirement."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3: fewer than 2 is not highly available, more than 3 is unnecessary here."
  }
}

variable "app_port" {
  description = "TCP port the application listens on inside the private subnets."
  type        = number
  default     = 3000
}

variable "single_nat_gateway" {
  description = <<-EOT
    Share one NAT Gateway across all private subnets instead of one per AZ.

    True is a deliberate cost trade-off: it saves roughly USD 32/month per
    avoided gateway, at the price of making the NAT a single-AZ dependency for
    outbound traffic. Acceptable here because outbound is only used for package
    installation and telemetry -- inbound request serving stays fully multi-AZ.
    See docs/decisions/0002-single-nat-gateway.md.
  EOT
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC flow logs. Kept short to control ingestion and storage cost."
  type        = number
  default     = 7
}

variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the public load balancer. Defaults to the internet, as this is a public storefront."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
