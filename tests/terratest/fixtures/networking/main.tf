# Test fixture: the networking module, standalone.
#
# A fixture rather than pointing Terratest at the module directly, so the test
# controls the provider configuration -- including default_tags, which the
# tagging policy requires and which a bare module has no way to set.

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
  default     = "10.99.0.0/16"
}

variable "single_nat_gateway" {
  description = "Whether the fixture shares one NAT Gateway across AZs."
  type        = bool
  default     = true
}

module "networking" {
  source = "../../../../terraform/modules/networking"

  name_prefix        = var.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = 2
  app_port           = 3000
  single_nat_gateway = var.single_nat_gateway

  flow_log_retention_days = 1
}

output "vpc_id" { value = module.networking.vpc_id }
output "vpc_cidr_block" { value = module.networking.vpc_cidr_block }
output "availability_zones" { value = module.networking.availability_zones }
output "public_subnet_ids" { value = module.networking.public_subnet_ids }
output "private_subnet_ids" { value = module.networking.private_subnet_ids }
output "public_subnet_cidrs" { value = module.networking.public_subnet_cidrs }
output "private_subnet_cidrs" { value = module.networking.private_subnet_cidrs }
output "alb_security_group_id" { value = module.networking.alb_security_group_id }
output "app_security_group_id" { value = module.networking.app_security_group_id }
output "nat_gateway_ids" { value = module.networking.nat_gateway_ids }
output "dynamodb_vpc_endpoint_id" { value = module.networking.dynamodb_vpc_endpoint_id }
output "flow_log_group_name" { value = module.networking.flow_log_group_name }
