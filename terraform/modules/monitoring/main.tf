# ---------------------------------------------------------------------------
# Monitoring module
#
# Observability and the cost guardrail:
#
#   * One SNS topic, subscribed by email, as the single notification channel.
#   * Four alarms, each tied to a documented operator action in RUNBOOK.md.
#   * One dashboard laid out so the top row answers "is the service healthy"
#     and the rows below answer "why".
#   * A monthly budget alert, so runaway spend is noticed by email rather than
#     by the credit card statement.
#
# The dashboard body lives in monitoring/dashboards/ rather than inline here,
# so the repository folder the brief asks for is the actual source of truth
# instead of a copy that drifts.
# ---------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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
# Notification channel
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name         = "${var.name_prefix}-alerts"
  display_name = "${var.name_prefix} alerts"

  tags = {
    Name = "${var.name_prefix}-alerts"
    Tier = "monitoring"
  }
}

# Only CloudWatch may publish here, and only alarms belonging to this account.
# Without this the topic policy defaults to account-root-only, which is fine,
# but being explicit documents the intended publisher.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid     = "AllowCloudWatchAlarmsToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid     = "AllowBudgetsToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid    = "AllowAccountOwnerFullControl"
    effect = "Allow"

    actions = [
      "SNS:Subscribe",
      "SNS:SetTopicAttributes",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:DeleteTopic",
      "SNS:Publish",
    ]

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }

    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# The address is supplied at apply time, never committed, because this
# repository is public. See scripts/lib.sh:ensure_alert_email.
#
# AWS sends a confirmation email; the subscription stays "pending" until the
# link is clicked. Terraform reports success either way, so a first-time
# apply needs that one manual confirmation before alerts actually deliver.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Alarms
#
# Thresholds are chosen so each alarm means something different. Overlapping
# alarms that all fire together train an operator to ignore the channel.
# ---------------------------------------------------------------------------

# 1. User-visible failure. The load balancer could not get a valid response
#    from any target -- the strongest single signal that the site is broken.
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

  # No requests at all produces no datapoints. Treating that as OK avoids a
  # false alarm every time the environment is torn down.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "${var.name_prefix}-elb-5xx"
    Severity = "critical"
  }
}

# 2. Capacity erosion. Fires before users notice, while the remaining
#    instances are still absorbing the traffic.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name        = "${var.name_prefix}-unhealthy-hosts"
  alarm_description = "At least one application instance is failing its health check. The ASG should replace it automatically; alarm if it does not clear. Runbook: RUNBOOK.md, 'Instance failing health checks'."

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

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "${var.name_prefix}-unhealthy-hosts"
    Severity = "high"
  }
}

# 3. Saturation. Set above the target-tracking setpoint so it only fires when
#    scaling is failing to keep up, not every time the policy is working.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name        = "${var.name_prefix}-cpu-high"
  alarm_description = "Fleet CPU is sustained above the scaling setpoint, which means auto scaling is not keeping up or has hit max_size. Runbook: RUNBOOK.md, 'Sustained high CPU'."

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

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "${var.name_prefix}-cpu-high"
    Severity = "medium"
  }
}

# 4. Degradation short of failure. Catches the slow-then-broken pattern that
#    error-rate alarms miss entirely.
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

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "${var.name_prefix}-latency-p95"
    Severity = "medium"
  }
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = local.dashboard_name

  dashboard_body = templatefile(var.dashboard_template_path, {
    name_prefix               = var.name_prefix
    region                    = data.aws_region.current.region
    alb_url                   = var.alb_url
    alb_arn_suffix            = var.alb_arn_suffix
    target_group_arn_suffix   = var.target_group_arn_suffix
    asg_name                  = var.autoscaling_group_name
    app_log_group             = var.app_log_group_name
    products_table_name       = var.products_table_name
    metrics_namespace         = var.metrics_namespace
    min_size                  = var.min_size
    cpu_target_utilization    = var.cpu_target_utilization
    cpu_alarm_threshold       = var.cpu_alarm_threshold
    latency_threshold_seconds = var.latency_p95_threshold_seconds
  })
}

# ---------------------------------------------------------------------------
# Budget guardrail
#
# The environment is torn down between working sessions, so the expected
# monthly spend is low. The point of this alert is to catch the case where a
# teardown silently failed and something has been billing for days.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  count = var.enable_budget_alert ? 1 : 0

  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Scoped by cost allocation tag, so this budget tracks only this project and
  # not anything else in the account.
  # AWS Budgets expects tag filters in the literal form "user:<Key>$<Value>".
  # Built with format() so the "$" stays a delimiter rather than being read as
  # the start of a Terraform interpolation.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_tag)]
  }

  # Actual spend crossing most of the budget.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  # Forecast crossing the whole budget. This is the one that catches a
  # forgotten NAT Gateway on day two rather than day twenty.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}
