# prod environment
#
# Every difference from dev is a deliberate reliability-over-cost trade.
# Read this file alongside dev/terraform.tfvars: the two are the same shape,
# so the production posture can be understood as a diff.
#
# NOTE: this environment is maintained as code but is not kept running. The
# capstone demo runs on dev, and leaving a second full stack up would roughly
# triple the monthly spend for no added marks. It is applied on demand to show
# the same codebase producing a production-grade posture.

aws_region  = "us-east-1"
environment = "prod"

# Network
# A distinct CIDR from dev, so the two could be peered or share a transit
# gateway later without renumbering.
vpc_cidr = "10.30.0.0/16"
az_count = 2

# One NAT Gateway per AZ. Roughly USD 32/month more than the shared gateway
# in dev, and the reason is availability: with a shared gateway, losing the
# AZ that hosts it takes outbound connectivity away from every private
# subnet. In prod that is not an acceptable failure mode.
single_nat_gateway = false

# Application tier
# A small burstable instance is still right for this workload, but with
# headroom above the three-instance floor and a lower scaling setpoint so the
# fleet grows before latency is affected rather than after.
instance_type          = "t4g.small"
instance_architecture  = "arm64"
min_size               = 3
max_size               = 12
desired_capacity       = 3
cpu_target_utilization = 40

# Data tier
# Deletion protection on: production data is not something a stray destroy
# should be able to remove. Longer retention for a real recovery window.
enable_point_in_time_recovery = true
enable_backup_plan            = true
backup_retention_days         = 35
enable_deletion_protection    = true

# Observability
# 30-day log retention for incident investigation, and detailed monitoring so
# scaling decisions and alarms work on 1-minute rather than 5-minute data.
log_retention_days            = 30
enable_detailed_monitoring    = true
cpu_alarm_threshold           = 70
latency_p95_threshold_seconds = 0.5

# Cost guardrail
enable_budget_alert = true
monthly_budget_usd  = 150
