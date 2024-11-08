// Main Terraform configuration for the SDC Pipeline

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.14.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.22.0"
    }

  }

  backend "s3" {
    bucket  = "smce-swsoc-terraform"
    key     = "smce-swsoc.terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }




}

provider "aws" {
  region = var.deployment_region
}



// Identify the current AWS account
data "aws_caller_identity" "current" {}

// Locals for SDC Pipeline
locals {
  workspace_prefix = split("-", terraform.workspace)[0]

  is_production = local.workspace_prefix == "prod"

  environment_short_name = {
    default = "dev-"
    dev     = "dev-"
    prod    = ""
  }[local.workspace_prefix]

  environment_full_name = {
    default = "Development"
    dev     = "Development"
    prod    = "Production"
  }[local.workspace_prefix]

  standard_tags = {
    "Environment" = local.environment_full_name
    "Purpose"     = "SWSOC Pipeline"
    "Project"     = var.mission_name
  }

  data_levels     = slice(var.valid_data_levels, 0, length(var.valid_data_levels))
  last_data_level = element(var.valid_data_levels, length(var.valid_data_levels) - 1)

  instrument_bucket_names = [for bucket in var.instrument_names : "${var.mission_name}-${bucket}"]
  bucket_list             = concat([var.incoming_bucket_name], local.instrument_bucket_names)
}


