# ---------------------------------------------------------------------------
# Monitoring module
#
# Alarms and the dashboard for one environment.
#
# The SNS topic and the budget deliberately do NOT live here -- they are in the
# bootstrap layer, because this platform is torn down between working sessions
# and both need to outlive it. An email subscription recreated on every
# bring-up would need re-confirming every time, and a budget destroyed with the
# environment cannot warn about resources a failed teardown left behind.
#
# This module therefore publishes into a channel it does not own, which is the
# right shape: the environment is ephemeral, the way you get told about it is
# not.
#
# The dashboard body lives in monitoring/dashboards/ rather than inline here,
# so that folder is the actual source of truth rather than a copy that drifts.
# ---------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_url = format(
    "https://%s.console.aws.amazon.com/cloudwatch/home?region=%s#dashboards/dashboard/%s",
    data.aws_region.current.region,
    data.aws_region.current.region,
    local.dashboard_name,
  )
}

# ---------------------------------------------------------------------------
# Alarms
#
# Four alarms, each detecting something the others do not. That is the design
# constraint: alarms that all fire together during the same incident teach an
# operator to ignore the channel.
#
# Every one sets treat_missing_data = "notBreaching", because a torn-down
# environment produces no datapoints and must not look like a failure.
#
# Full reasoning for each threshold is in monitoring/alerts/README.md.
# ---------------------------------------------------------------------------

# 1. User-visible failure. The load balancer could not get a valid response from
#    any healthy target -- the strongest single signal that the site is broken.
resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  alarm_name        = "${var.name_prefix}-elb-5xx"
  alarm_description = "Load balancer returned 5xx responses it generated itself, meaning no healthy target could serve the request. Runbook: RUNBOOK.md, 'Storefront returning 5xx'."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_ELB_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.elb_5xx_threshold
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  treat_missing_data = "notBreaching"

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name     = "${var.name_prefix}-elb-5xx"
    Severity = "critical"
  }
}

# 2. Capacity erosion. Fires while the remaining instances are still absorbing
#    the traffic, which is before users notice.
#
#    Because the Auto Scaling group replaces unhealthy instances by itself, this
#    alarm does not really mean "an instance failed" -- it means an instance
#    failed and the automation has not fixed it. Three minutes is roughly how
#    long a replacement takes.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name        = "${var.name_prefix}-unhealthy-hosts"
  alarm_description = "An application instance is failing its health check and has not been replaced. Runbook: RUNBOOK.md, 'Instance failing health checks'."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  treat_missing_data = "notBreaching"

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name     = "${var.name_prefix}-unhealthy-hosts"
    Severity = "high"
  }
}

# 3. Saturation. The threshold sits deliberately ABOVE the target-tracking
#    setpoint: the scaling policy is supposed to hold the fleet near its
#    setpoint, so sustained CPU well above it means scaling is not keeping up or
#    the group has hit max_size. An alarm at the setpoint would fire every time
#    the system worked correctly.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name        = "${var.name_prefix}-cpu-high"
  alarm_description = "Fleet CPU is sustained above the scaling setpoint, so auto scaling is not keeping up or has hit its ceiling. Runbook: RUNBOOK.md, 'Sustained high CPU'."

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"

  dimensions = {
    AutoScalingGroupName = var.autoscaling_group_name
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_alarm_threshold
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  treat_missing_data = "notBreaching"

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name     = "${var.name_prefix}-cpu-high"
    Severity = "medium"
  }
}

# 4. Degradation short of failure. Catches the slow-then-broken pattern that
#    error-rate alarms miss entirely, and is usually the first alarm to fire in
#    a gradual incident.
#
#    p95 rather than average: a fleet where one instance in ten is timing out
#    has a barely-moved average and a p95 through the roof.
resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name        = "${var.name_prefix}-latency-p95"
  alarm_description = "95th percentile response time exceeded its budget. The service is degraded but still answering. Runbook: RUNBOOK.md, 'Elevated latency'."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p95_threshold_seconds
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2

  treat_missing_data = "notBreaching"

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]

  tags = {
    Name     = "${var.name_prefix}-latency-p95"
    Severity = "medium"
  }
}

# ---------------------------------------------------------------------------
# Dashboard
#
# Laid out so the top row answers "is the service healthy for users" and the
# rows below answer "why". Alarm thresholds are drawn on the relevant widgets as
# annotations, so a reader can see how close to the edge the system is running
# without opening the alarm definitions.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = local.dashboard_name

  dashboard_body = templatefile(var.dashboard_template_path, {
    name_prefix             = var.name_prefix
    region                  = data.aws_region.current.region
    alb_url                 = var.alb_url
    alb_arn_suffix          = var.alb_arn_suffix
    target_group_arn_suffix = var.target_group_arn_suffix
    asg_name                = var.autoscaling_group_name
    app_log_group           = var.app_log_group_name
    products_table_name     = var.products_table_name
    metrics_namespace       = var.metrics_namespace

    # Passed through so the dashboard annotations and the alarm thresholds
    # cannot drift apart -- both read the same variables.
    min_size                  = var.min_size
    cpu_target_utilization    = var.cpu_target_utilization
    cpu_alarm_threshold       = var.cpu_alarm_threshold
    latency_threshold_seconds = var.latency_p95_threshold_seconds
  })
}
