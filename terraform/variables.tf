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

variable "sorting_lambda_bucket_name" {
  type        = string
  description = "The name of the S3 bucket to create for storing the sorting lambda"
}

variable "s3_server_access_logs_bucket_name" {
  type        = string
  description = "The name of the S3 bucket to create for storing access logs"
}

variable "processing_function_private_ecr_name" {
  type        = string
  description = "Private ECR repository for the processing function"
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

variable "image_tag" {
  type        = string
  description = "ECR image tag"
  default     = "latest"
}

variable "s3_key" {
  type = string
  description = "S3 key for the sorting lambda"
}

variable "valid_data_levels" {
  type        = list(string)
  description = "The list of valid data levels"
}