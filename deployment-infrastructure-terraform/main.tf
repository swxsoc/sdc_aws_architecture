terraform {
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.96.0"
    }
  }

  backend "s3" {
    bucket       = "smce-swsoc-terraform"
    key          = "swxsoc-codebuild.terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.deployment_region

  default_tags {
    tags = {
      Environment = "Shared"
      ManagedBy   = "terraform"
      Project     = "swxsoc"
      Purpose     = "Lambda image deployment"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
