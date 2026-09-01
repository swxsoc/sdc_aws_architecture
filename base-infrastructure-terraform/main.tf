// Main Terraform configuration for the SDC Pipeline

terraform {
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.96.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.4"
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

  default_tags {
    tags = local.standard_tags
  }
}

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

  environment_slug    = local.workspace_prefix == "dev" ? "dev" : "prod"
  secret_path_root    = "swxsoc/${local.environment_slug}/${replace(lower(var.soc_name), "_", "-")}"
  grafana_secret_name = "${local.secret_path_root}/executor/grafana"
  udl_secret_name     = trimspace(var.udl_secret_name) != "" ? var.udl_secret_name : "${local.secret_path_root}/executor/udl"

  required_tags = {
    "Mission" = var.soc_name
    "Service" = var.service_name
  }

  standard_tags = merge(local.required_tags, {
    "Environment" = local.environment_full_name
    "ManagedBy"   = "terraform"
    "Purpose"     = "SWSOC Base Infrastructure"
    "Project"     = var.soc_name
  })

  ecr_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the newest 15 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 15
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

}
