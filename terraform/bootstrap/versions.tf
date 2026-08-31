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

  # Cost allocation tags applied to every taggable resource in this layer.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "shared"
      Layer       = "bootstrap"
      ManagedBy   = "terraform"
      Owner       = var.owner
      CostCenter  = var.cost_center
    }
  }
}
