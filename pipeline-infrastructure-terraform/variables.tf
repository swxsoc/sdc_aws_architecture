// Variables for the Terraform deployment

variable "deployment_region" {
  type        = string
  description = "The AWS region to deploy to"
}

variable "timestream_database_name" {
  type        = string
  description = "The name of the Timestream database to create"
}

variable "timestream_s3_logs_table_name" {
  type        = string
  description = "The name of the Timestream table to create"
}

variable "incoming_bucket_name" {
  type        = string
  description = "The name of the S3 bucket to create for storing incoming files"
}

variable "instrument_names" {
  type        = list(string)
  description = "The list of instruments"
}

variable "mission_name" {
  type        = string
  description = "Mission identifier used for resource names and tags"

  validation {
    condition     = trimspace(var.mission_name) != ""
    error_message = "mission_name must not be empty."
  }
}

variable "service_name" {
  type        = string
  description = "Service tag applied to all mission pipeline resources"
  default     = "sdc-aws-pipeline"

  validation {
    condition     = trimspace(var.service_name) != ""
    error_message = "service_name must not be empty."
  }
}

variable "resource_purpose" {
  type        = string
  description = "Purpose tag applied to mission resources"
  default     = "SWSOC Pipeline"
}

variable "s3_server_access_logs_bucket_name" {
  type        = string
  description = "The name of the S3 bucket to create for storing access logs"
}

variable "sorting_function_private_ecr_name" {
  type        = string
  description = "Private ECR repository for the sorting function"
}

variable "processing_function_private_ecr_name" {
  type        = string
  description = "Private ECR repository for the processing function"
}

variable "concating_function_private_ecr_name" {
  type        = string
  description = "Private ECR repository for the concating function"
  default     = ""
}

variable "needs_concating" {
  description = "Whether to create the concating Lambda function and related resources"
  type        = bool
  default     = false
}

variable "artifacts_function_private_ecr_name" {
  type        = string
  description = "Private ECR repository for the artifacts function"
}

variable "docker_base_public_ecr_name" {
  type        = string
  description = "Public ECR repository for the docker base image"
}

variable "slack_token" {
  type        = string
  description = "Slack token for posting messages"
  default     = "slack_token"
  sensitive   = true
}

variable "slack_channel" {
  type        = string
  description = "Slack channel for posting messages"
  default     = "slack_channel"
  sensitive   = true
}

variable "enable_grafana_secret" {
  type        = bool
  description = "Whether to read Grafana credentials from Secrets Manager"
  default     = true
}

variable "grafana_secret_name" {
  type        = string
  description = "Optional Grafana secret name; defaults to swxsoc/<environment>/<mission>/processing/grafana"
  default     = ""
}

variable "enable_mattermost" {
  type        = bool
  description = "Whether to inject Mattermost configuration into Sorting and Artifacts"
  default     = false
}

variable "comms_platform" {
  type        = string
  description = "Explicit communications platform exposed to Sorting and Artifacts; empty preserves legacy platform auto-detection"
  default     = ""

  validation {
    condition     = contains(["", "slack", "mattermost"], lower(trimspace(var.comms_platform)))
    error_message = "comms_platform must be empty, slack, or mattermost."
  }
}

variable "mattermost_secret_name" {
  type        = string
  description = "Optional Mattermost secret name; defaults to swxsoc/<environment>/<mission>/communications/mattermost"
  default     = ""
}

variable "mattermost_url" {
  type        = string
  description = "Mattermost server URL"
  default     = "https://mm.sciencecloud.nasa.gov:443"

  validation {
    condition     = !var.enable_mattermost || startswith(var.mattermost_url, "https://")
    error_message = "mattermost_url must use HTTPS when Mattermost is enabled."
  }
}

variable "enable_processing_lambda" {
  type        = bool
  description = "Whether to create the processing Lambda and related resources"
  default     = true
}

variable "enable_sorting_lambda" {
  type        = bool
  description = "Whether to create the sorting Lambda and related resources"
  default     = true
}

variable "enable_artifacts_lambda" {
  type        = bool
  description = "Whether to create the artifacts Lambda and related resources"
  default     = true
}

variable "enable_concating_lambda" {
  type        = bool
  description = "Whether to create the concating Lambda and related resources"
  default     = true
}

variable "pf_image_tag" {
  type        = string
  description = "Immutable Processing Function ECR image tag; required when no full image URI override is supplied"
  default     = ""

  validation {
    condition     = trimspace(var.pf_image_tag) == "" || lower(trimspace(var.pf_image_tag)) != "latest"
    error_message = "pf_image_tag must be immutable; the mutable latest tag is not allowed."
  }
}

variable "cf_image_tag" {
  type        = string
  description = "Immutable Concating Function ECR image tag; required when no full image URI override is supplied"
  default     = ""

  validation {
    condition     = trimspace(var.cf_image_tag) == "" || lower(trimspace(var.cf_image_tag)) != "latest"
    error_message = "cf_image_tag must be immutable; the mutable latest tag is not allowed."
  }
}

variable "sf_image_tag" {
  type        = string
  description = "Immutable Sorting Function ECR image tag; required when no full image URI override is supplied"
  default     = ""

  validation {
    condition     = trimspace(var.sf_image_tag) == "" || lower(trimspace(var.sf_image_tag)) != "latest"
    error_message = "sf_image_tag must be immutable; the mutable latest tag is not allowed."
  }
}

variable "af_image_tag" {
  type        = string
  description = "Immutable Artifacts Function ECR image tag; required when no full image URI override is supplied"
  default     = ""

  validation {
    condition     = trimspace(var.af_image_tag) == "" || lower(trimspace(var.af_image_tag)) != "latest"
    error_message = "af_image_tag must be immutable; the mutable latest tag is not allowed."
  }
}

variable "processing_image_uri_override" {
  type        = string
  description = "Optional full image URI to use for the processing Lambda (overrides repo/tag)"
  default     = ""
}

variable "sorting_image_uri_override" {
  type        = string
  description = "Optional full image URI to use for the sorting Lambda (overrides repo/tag)"
  default     = ""
}

variable "concating_image_uri_override" {
  type        = string
  description = "Optional full image URI to use for the concating Lambda (overrides repo/tag)"
  default     = ""
}

variable "artifacts_image_uri_override" {
  type        = string
  description = "Optional full image URI to use for the artifacts Lambda (overrides repo/tag)"
  default     = ""
}

variable "valid_data_levels" {
  type        = list(string)
  description = "The list of valid data levels"
}

variable "optional_s3_uploader_role_arn" {
  type    = string
  default = ""
}

variable "optional_s3_uploader_role_arns" {
  type        = list(string)
  description = "Optional IAM role ARNs allowed to upload to incoming bucket"
  default     = []
}

variable "enable_lambda_vpc" {
  type        = bool
  description = "Whether to attach Lambdas to a VPC"
  default     = true
}

variable "lambda_vpc_subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for Lambda VPC config"
  default     = ["subnet-0972d4965ef8eb1e8", "subnet-0e24325c69b9a1f74"]
}

variable "rds_additional_security_group_ids" {
  type        = list(string)
  description = "Additional security groups allowed to access RDS"
  default     = ["sg-002dbe7887ac759c5"]
}

variable "rds_ingress_cidr_blocks" {
  type        = list(string)
  description = "Additional CIDR blocks allowed to access RDS"
  default     = []
}

variable "rds_engine_version" {
  type        = string
  description = "Postgres engine version for the RDS instance"
  default     = "14.12"
}
