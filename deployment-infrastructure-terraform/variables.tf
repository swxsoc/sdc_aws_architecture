variable "deployment_region" {
  type        = string
  description = "AWS region containing the private ECR repositories, CodeBuild projects, and Lambda functions"
  default     = "us-east-1"
}

variable "adopt_existing_codebuild_projects" {
  type        = bool
  description = "Whether declarative import blocks should adopt the existing CodeBuild projects and webhooks"
  default     = true
}

variable "shared_codeconnection_arn" {
  type        = string
  description = "CodeConnection used for SWxSOC repositories"
  default     = "arn:aws:codeconnections:us-east-1:351967858401:connection/c1e46862-71d8-44de-bcbb-2c2fe83b4b94"
}

variable "padre_codeconnection_arn" {
  type        = string
  description = "CodeConnection used for PADRE repositories"
  default     = "arn:aws:codeconnections:us-east-1:351967858401:connection/903691fc-989f-4405-b420-2e2393aa1e43"
}

variable "hermes_codeconnection_arn" {
  type        = string
  description = "CodeConnection used for HERMES repositories"
  default     = "arn:aws:codestar-connections:us-east-1:351967858401:connection/4296e8d0-c3c9-4470-9d58-b955889ce226"
}

variable "codebuild_log_retention_days" {
  type        = number
  description = "CloudWatch retention in days for every managed CodeBuild log group"
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.codebuild_log_retention_days)
    error_message = "codebuild_log_retention_days must be a CloudWatch Logs supported retention period."
  }
}
