# Test fixture: the full platform, sized down.
#
# Composes the same three modules the dev environment does, so the end-to-end
# test exercises the real wiring between them rather than a simplified stand-in.
# Retention and backup settings are minimised because the stack lives for about
# fifteen minutes.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ce-capstone"
      Environment = "test"
      ManagedBy   = "terraform"
      Owner       = "terratest"
      CostCenter  = "ironhack-bootcamp"
    }
  }
}

variable "aws_region" {
  description = "Region the fixture is created in."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Unique per test run, so parallel runs cannot collide."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the test VPC."
  type        = string
  default     = "10.98.0.0/16"
}

locals {
  common_tags = {
    Project     = "ce-capstone"
    Environment = "test"
    ManagedBy   = "terraform"
    Owner       = "terratest"
    CostCenter  = "ironhack-bootcamp"
  }
}

module "networking" {
  source = "../../../../terraform/modules/networking"

  name_prefix             = var.name_prefix
  vpc_cidr                = var.vpc_cidr
  az_count                = 2
  app_port                = 3000
  single_nat_gateway      = true
  flow_log_retention_days = 1
}

module "data" {
  source = "../../../../terraform/modules/data"

  name_prefix = var.name_prefix

  # The backup plan is asserted by its own unit-level checks. Creating a vault
  # per end-to-end run would leave recovery points behind after teardown.
  enable_backup_plan            = false
  enable_point_in_time_recovery = true
  enable_deletion_protection    = false
}

module "compute" {
  source = "../../../../terraform/modules/compute"

  name_prefix = var.name_prefix
  environment = "test"
  tags        = local.common_tags

  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  private_subnet_ids    = module.networking.private_subnet_ids
  alb_security_group_id = module.networking.alb_security_group_id
  app_security_group_id = module.networking.app_security_group_id

  products_table_name = module.data.products_table_name
  products_table_arn  = module.data.products_table_arn

  app_source_path = "${path.module}/../../../../app/src/server.js"

  min_size           = 3
  max_size           = 4
  desired_capacity   = 3
  log_retention_days = 1
}

output "storefront_url" { value = module.compute.alb_url }
output "target_group_arn" { value = module.compute.target_group_arn }
output "autoscaling_group_name" { value = module.compute.autoscaling_group_name }
output "products_table_name" { value = module.data.products_table_name }
output "app_log_group_name" { value = module.compute.app_log_group_name }
output "private_subnet_ids" { value = module.networking.private_subnet_ids }
