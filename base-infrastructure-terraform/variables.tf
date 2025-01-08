// Variables for the Terraform deployment

variable "deployment_region" {
  type        = string
  description = "The AWS region to deploy to"
}

variable "soc_name" {
  type        = string
  description = "The name of the soc to create base resources"
}

variable "timestream_database_name" {
  type        = string
  description = "The name of the Timestream database to create"
}

variable "timestream_measures_table_name" {
  type        = string
  description = "The name of the Timestream table to create"
}

variable "executor_function_private_ecr_name" {
  type        = string
  description = "Private ECR repository for the processing function"
}

variable "ef_image_tag" {
  type        = string
  description = "Executor Function ECR image tag"
  default     = "latest"
}