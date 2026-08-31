# ---------------------------------------------------------------------------
# Shared alerting channel and cost guardrail
#
# These live in the bootstrap layer rather than alongside the alarms they serve,
# for two reasons that both come from this platform being torn down between
# working sessions.
#
# The SNS email subscription needs a confirmation click before it delivers
# anything. If the topic were created per environment, every single bring-up
# would produce a fresh unconfirmed subscription and a fresh confirmation email
# -- and an alert channel that has to be re-armed on every deploy is one that
# will eventually be ignored. Here it is confirmed once and outlives every
# environment.
#
# The budget is here for a sharper reason: the moment you most want a cost alert
# is right after a teardown that did not fully succeed. A budget destroyed
# along with the environment cannot warn about the resources the destroy
# missed.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:SSE with the AWS-managed key would silently break alarm delivery; see SECURITY.md
  name         = "${var.project_name}-alerts"
  display_name = "${var.project_name} alerts"

  tags = {
    Name = "${var.project_name}-alerts"
  }
}

data "aws_iam_policy_document" "alerts_topic" {
  # CloudWatch alarms in this account, and nothing else, may publish.
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

# The address is supplied at apply time via TF_VAR_alert_email and is never
# committed, because this repository is public.
#
# AWS sends a confirmation email and the subscription stays PendingConfirmation
# until the link is clicked. Terraform reports success either way, so a first
# apply produces alarms that fire into nothing until that one click happens.
# RUNBOOK.md covers verifying it.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Budget
#
# Scoped by the Project cost allocation tag, so it tracks this workload rather
# than everything in the account.
#
# The forecast notification is the one that earns its keep: it catches a
# forgotten NAT Gateway on day two rather than on the statement at the end of
# the month.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "project" {
  count = var.enable_budget_alert ? 1 : 0

  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # AWS Budgets expects tag filters in the literal form "user:<Key>$<Value>".
  # Built with format() so the "$" stays a delimiter rather than being read as
  # the start of a Terraform interpolation.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_name)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

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
