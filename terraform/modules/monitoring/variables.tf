variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. ce-capstone-dev."
  type        = string
}

variable "alerts_topic_arn" {
  description = <<-EOT
    SNS topic every alarm publishes to.

    Created in the bootstrap layer rather than by this module, so the email
    subscription survives an environment teardown and does not need
    re-confirming on every bring-up. See terraform/bootstrap/alerts.tf.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:sns:", var.alerts_topic_arn))
    error_message = "alerts_topic_arn must be an SNS topic ARN."
  }
}

variable "dashboard_template_path" {
  description = "Path to the dashboard body template under monitoring/dashboards/."
  type        = string
}

# --- Resources being monitored ----------------------------------------------

variable "alb_url" {
  description = "Storefront URL, shown in the dashboard header for one-click access during an incident."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix, the dimension CloudWatch uses for load balancer metrics."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix, the dimension CloudWatch uses for target metrics."
  type        = string
}

variable "autoscaling_group_name" {
  description = "Auto Scaling group name, the dimension for EC2 and capacity metrics."
  type        = string
}

variable "app_log_group_name" {
  description = "Application log group queried by the dashboard log widget."
  type        = string
}

variable "products_table_name" {
  description = "DynamoDB catalog table name, the dimension for data tier metrics."
  type        = string
}

variable "metrics_namespace" {
  description = "CloudWatch namespace for custom metrics published by the agent."
  type        = string
  default     = "CeCapstone"
}

# --- Alarm thresholds -------------------------------------------------------

variable "elb_5xx_threshold" {
  description = "Load balancer 5xx responses per minute before the critical alarm fires."
  type        = number
  default     = 5
}

variable "cpu_alarm_threshold" {
  description = "Average fleet CPU percentage that signals scaling is not keeping up. Must sit above the scaling setpoint."
  type        = number
  default     = 80
}

variable "latency_p95_threshold_seconds" {
  description = "95th percentile response time budget, in seconds."
  type        = number
  default     = 1.0
}

variable "cpu_target_utilization" {
  description = "Scaling policy setpoint, drawn on the dashboard for context."
  type        = number
  default     = 50
}

variable "min_size" {
  description = "Minimum instance count, drawn on the target health widget for context."
  type        = number
  default     = 3
}
