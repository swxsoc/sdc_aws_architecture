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

locals {
  workspace_prefix = split("-", terraform.workspace)[0]

  environment_short_name = {
    default = ""
    dev     = "dev-"
    prod    = ""
  }[local.workspace_prefix]

  environment_full_name = {
    default = "Production"
    dev     = "Development"
    prod    = "Production"
  }[local.workspace_prefix]

  standard_tags = {
    "Environment" = local.environment_full_name
    "Purpose"     = "SWSOC Base Infrastructure"
    "Project"     = var.soc_name
  }

}
