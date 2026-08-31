output "alerts_topic_arn" {
  description = "SNS topic every alarm and budget notification publishes to."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.overview.dashboard_name
}

output "dashboard_url" {
  description = "Direct console link to the dashboard. Printed by scripts/up.sh."
  value       = local.dashboard_url
}

output "alarm_names" {
  description = "Every alarm created by this module, in decreasing severity."
  value = [
    aws_cloudwatch_metric_alarm.elb_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name,
    aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.latency_p95.alarm_name,
  ]
}

output "alarm_count" {
  description = "Number of configured alarms. The project requires at least three."
  value       = 4
}

output "budget_name" {
  description = "Monthly cost budget name, or null when the budget alert is disabled."
  value       = var.enable_budget_alert ? aws_budgets_budget.monthly[0].name : null
}
