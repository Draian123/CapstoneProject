# dev environment
#
# Sized for demonstration and iteration: smallest instances that meet the
# three-instance requirement, shortest log retention that is still useful, and
# every deletion-protection flag off so the environment can be destroyed
# between working sessions. See COSTS.md for what each choice saves.

aws_region  = "us-east-1"
environment = "dev"

# Network
vpc_cidr           = "10.20.0.0/16"
az_count           = 2
single_nat_gateway = true

# Application tier
instance_type          = "t4g.micro"
instance_architecture  = "arm64"
min_size               = 3
max_size               = 6
desired_capacity       = 3
cpu_target_utilization = 50

# Data tier
enable_point_in_time_recovery = true
enable_backup_plan            = true
backup_retention_days         = 7
enable_deletion_protection    = false

# Observability
log_retention_days            = 7
enable_detailed_monitoring    = false
cpu_alarm_threshold           = 80
latency_p95_threshold_seconds = 1.0

# Cost guardrail
# The budget lives in the bootstrap layer: it covers the whole project and
# must survive a teardown, since a failed teardown is exactly when a cost
# alert matters most.
