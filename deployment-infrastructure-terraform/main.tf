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

  # SMCE tags S3, RDS, and EC2 resources with SMCE_Owner (the creator) outside
  # Terraform. Ignore it so it is neither reported as drift nor removed.
  ignore_tags {
    keys = ["SMCE_Owner"]
  }

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

# The GDC-Trailblazer connection is created in the console, so it is looked up
# by name instead of carrying its ARN in the repository.
data "aws_codestarconnections_connection" "gdctb" {
  count = trimspace(var.gdctb_codeconnection_name) != "" ? 1 : 0
  name  = var.gdctb_codeconnection_name
}
