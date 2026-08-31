# ---------------------------------------------------------------------------
# prod environment
#
# The root module: it composes the four reusable modules and holds nothing
# else. Every value that differs between dev and prod is a variable set in
# terraform.tfvars, so the difference between the two environments can be read
# in one file rather than diffed across a tree.
#
# Bring it up with   scripts/up.sh prod
# Tear it down with  scripts/down.sh prod
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Applied by the provider to everything taggable, and passed explicitly to
  # the compute module for the ASG-launched instances and volumes that
  # default_tags cannot reach.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
    CostCenter  = var.cost_center
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ---------------------------------------------------------------------------
# Network foundation
# ---------------------------------------------------------------------------

module "networking" {
  source = "../../modules/networking"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
  app_port    = var.app_port

  single_nat_gateway      = var.single_nat_gateway
  flow_log_retention_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Data tier
#
# Created before compute: the instance role is scoped to this table's ARN, so
# compute depends on it.
# ---------------------------------------------------------------------------

module "data" {
  source = "../../modules/data"

  name_prefix = local.name_prefix

  enable_point_in_time_recovery = var.enable_point_in_time_recovery
  enable_backup_plan            = var.enable_backup_plan
  backup_retention_days         = var.backup_retention_days

  # Left off in dev so scripts/down.sh can destroy the environment between
  # working sessions without manual intervention.
  enable_deletion_protection = var.enable_deletion_protection
}

# ---------------------------------------------------------------------------
# Application tier
# ---------------------------------------------------------------------------

module "compute" {
  source = "../../modules/compute"

  name_prefix = local.name_prefix
  environment = var.environment
  tags        = local.common_tags

  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  private_subnet_ids    = module.networking.private_subnet_ids
  alb_security_group_id = module.networking.alb_security_group_id
  app_security_group_id = module.networking.app_security_group_id

  products_table_name = module.data.products_table_name
  products_table_arn  = module.data.products_table_arn

  # The application is embedded into instance user-data at apply time, so
  # editing app/src/server.js and re-applying performs a rolling deployment.
  app_source_path = "${path.module}/../../../app/src/server.js"
  app_port        = var.app_port

  instance_type         = var.instance_type
  instance_architecture = var.instance_architecture
  min_size              = var.min_size
  max_size              = var.max_size
  desired_capacity      = var.desired_capacity

  cpu_target_utilization     = var.cpu_target_utilization
  log_retention_days         = var.log_retention_days
  metrics_namespace          = var.metrics_namespace
  enable_detailed_monitoring = var.enable_detailed_monitoring
  enable_deletion_protection = var.enable_deletion_protection
}

# ---------------------------------------------------------------------------
# Observability and cost guardrail
# ---------------------------------------------------------------------------

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix = local.name_prefix
  project_tag = var.project_name
  alert_email = var.alert_email

  # The dashboard body is authored under monitoring/dashboards/ so that folder
  # is the single source of truth rather than a copy of what is in state.
  dashboard_template_path = "${path.module}/../../../monitoring/dashboards/platform-overview.json.tftpl"

  alb_url                 = module.compute.alb_url
  alb_arn_suffix          = module.compute.alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  autoscaling_group_name  = module.compute.autoscaling_group_name
  app_log_group_name      = module.compute.app_log_group_name
  products_table_name     = module.data.products_table_name
  metrics_namespace       = var.metrics_namespace

  # Kept consistent with the scaling policy so the dashboard annotations and
  # the alarm thresholds cannot drift apart.
  cpu_target_utilization        = var.cpu_target_utilization
  cpu_alarm_threshold           = var.cpu_alarm_threshold
  latency_p95_threshold_seconds = var.latency_p95_threshold_seconds
  min_size                      = var.min_size

  enable_budget_alert = var.enable_budget_alert
  monthly_budget_usd  = var.monthly_budget_usd
}
