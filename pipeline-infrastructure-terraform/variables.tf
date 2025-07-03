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

variable "valid_data_levels" {
  type        = list(string)
  description = "The list of valid data levels"
}

variable "optional_s3_uploader_role_arn" {
  type    = string
  default = ""
}
