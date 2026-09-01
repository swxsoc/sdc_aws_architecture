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

  default_tags {
    tags = local.standard_tags
  }
}



// Identify the current AWS account
data "aws_caller_identity" "current" {
  lifecycle {
    precondition {
      condition     = terraform.workspace != "default"
      error_message = "The pipeline root must use an explicit <environment>-<mission> workspace; the default workspace is reserved for base infrastructure."
    }
  }
}

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

  environment_slug       = local.is_production ? "prod" : "dev"
  mission_slug           = replace(lower(var.mission_name), "_", "-")
  secret_path_root       = "swxsoc/${local.environment_slug}/${local.mission_slug}"
  grafana_secret_name    = trimspace(var.grafana_secret_name) != "" ? var.grafana_secret_name : "${local.secret_path_root}/processing/grafana"
  mattermost_secret_name = trimspace(var.mattermost_secret_name) != "" ? var.mattermost_secret_name : "${local.secret_path_root}/communications/mattermost"
  rds_secret_name        = "${local.secret_path_root}/processing/rds"

  required_tags = {
    "Mission" = var.mission_name
    "Service" = var.service_name
  }

  standard_tags = merge(local.required_tags, {
    "Environment" = local.environment_full_name
    "ManagedBy"   = "terraform"
    "Purpose"     = var.resource_purpose
    "Project"     = var.mission_name
  })

  data_levels = slice(var.valid_data_levels, 0, length(var.valid_data_levels))

  optional_s3_uploader_role_arns = compact(
    concat(
      var.optional_s3_uploader_role_arns,
      var.optional_s3_uploader_role_arn != "" ? [var.optional_s3_uploader_role_arn] : []
    )
  )

  mission_bucket_prefix   = replace(var.mission_name, "_", "-")
  instrument_bucket_names = [for bucket in var.instrument_names : "${local.mission_bucket_prefix}-${bucket}"]
  bucket_list             = concat([var.incoming_bucket_name], local.instrument_bucket_names)

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
