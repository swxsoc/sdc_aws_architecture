// Variables for the Terraform deployment

variable "deployment_region" {
  type        = string
  description = "The AWS region to deploy to"
}

variable "soc_name" {
  type        = string
  description = "The name of the soc to create base resources"

  validation {
    condition     = trimspace(var.soc_name) != ""
    error_message = "soc_name must not be empty."
  }
}

variable "service_name" {
  type        = string
  description = "Service tag applied to all base infrastructure resources"
  default     = "sdc-aws-base-infrastructure"

  validation {
    condition     = trimspace(var.service_name) != ""
    error_message = "service_name must not be empty."
  }
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

variable "executor_memory_size" {
  type        = number
  description = "Executor Lambda memory in MB"
  default     = 1024
}

variable "executor_ephemeral_storage_size" {
  type        = number
  description = "Executor Lambda ephemeral storage in MB"
  default     = 2048
}

variable "udl_secret_name" {
  type        = string
  description = "Name of the existing UDL credentials secret"
  default     = "udl-credentials"

  validation {
    condition     = trimspace(var.udl_secret_name) != ""
    error_message = "udl_secret_name must not be empty."
  }
}

variable "github_report_bucket_name" {
  type        = string
  description = "S3 bucket used for generated repository reports"
  default     = "swxsoc-github"
}

variable "reach_destination_bucket_dev" {
  type        = string
  description = "Development destination for scheduled REACH downloads"
  default     = "dev-swxsoc-pipeline-incoming"
}

variable "reach_destination_bucket_prod" {
  type        = string
  description = "Production destination for scheduled REACH downloads"
  default     = "swxsoc-pipeline-incoming"
}

variable "s3_access_bucket_name" {
  type        = string
  description = "Optional single S3 bucket name to grant access to"
  default     = ""
}

variable "s3_access_bucket_names" {
  type        = list(string)
  description = "Optional S3 bucket names to grant access to"
  default     = []
}

variable "name" {
  type        = string
  description = "Name for the optional promtail Lambda"
  default     = ""
}

variable "lambda_vpc_subnets" {
  type        = list(string)
  description = "Subnet IDs for the optional promtail Lambda VPC config"
  default     = []
}

variable "lambda_vpc_security_groups" {
  type        = list(string)
  description = "Security group IDs for the optional promtail Lambda VPC config"
  default     = []
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for the optional promtail Lambda"
  default     = ""
}

variable "bucket_names" {
  type        = set(string)
  description = "S3 bucket names to subscribe to for the optional promtail Lambda"
  default     = []
}

variable "kinesis_stream_name" {
  type        = set(string)
  description = "Kinesis stream names for the optional promtail Lambda"
  default     = []
}

variable "log_group_names" {
  type        = set(string)
  description = "CloudWatch log group names for the optional promtail Lambda"
  default     = []
}

variable "lambda_promtail_image" {
  type        = string
  description = "Optional promtail Lambda image URI (empty for zip build)"
  default     = ""
}

variable "write_address" {
  type        = string
  description = "Promtail write address"
  default     = ""
}

variable "username" {
  type        = string
  description = "Promtail username"
  default     = ""
}

variable "password" {
  type        = string
  description = "Promtail password"
  default     = ""
}

variable "bearer_token" {
  type        = string
  description = "Promtail bearer token"
  default     = ""
}

variable "keep_stream" {
  type        = string
  description = "Promtail keep stream setting"
  default     = ""
}

variable "batch_size" {
  type        = string
  description = "Promtail batch size"
  default     = ""
}

variable "extra_labels" {
  type        = string
  description = "Promtail extra labels"
  default     = ""
}

variable "drop_labels" {
  type        = string
  description = "Promtail drop labels"
  default     = ""
}

variable "omit_extra_labels_prefix" {
  type        = bool
  description = "Whether to omit extra labels prefix"
  default     = false
}

variable "tenant_id" {
  type        = string
  description = "Promtail tenant ID"
  default     = ""
}

variable "skip_tls_verify" {
  type        = string
  description = "Promtail skip TLS verify setting"
  default     = ""
}

variable "print_log_line" {
  type        = string
  description = "Promtail print log line setting"
  default     = ""
}

variable "filter_prefix" {
  type        = string
  description = "S3 notification filter prefix"
  default     = ""
}

variable "filter_suffix" {
  type        = string
  description = "S3 notification filter suffix"
  default     = ""
}

variable "sqs_enabled" {
  type        = bool
  description = "Whether SQS is enabled for promtail S3 notifications"
  default     = false
}
