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
  description = "The list of missions"
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
  description = "Secrets Manager secret name for Grafana credentials"
  default     = "grafana-credentials"
}

variable "pf_image_tag" {
  type        = string
  description = "Processing Function ECR image tag"
  default     = "latest"
}

variable "cf_image_tag" {
  type        = string
  description = "Processing Function ECR image tag"
  default     = "latest"
}

variable "sf_image_tag" {
  type        = string
  description = "Sorting Function ECR image tag"
  default     = "latest"
}

variable "af_image_tag" {
  type        = string
  description = "Artifact Function ECR image tag"
  default     = "latest"
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
  default     = ["86.21.42.229/32"]
}
