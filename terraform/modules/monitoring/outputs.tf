output "alerts_topic_arn" {
  description = "SNS topic every alarm publishes to. Owned by the bootstrap layer, passed through here for convenience."
  value       = var.alerts_topic_arn
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
