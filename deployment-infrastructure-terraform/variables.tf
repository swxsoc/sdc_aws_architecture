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
  description = "CodeConnection used for SWxSOC and PADRE repositories"
  default     = "arn:aws:codeconnections:us-east-1:351967858401:connection/c1e46862-71d8-44de-bcbb-2c2fe83b4b94"
}

variable "hermes_codeconnection_arn" {
  type        = string
  description = "CodeConnection used for HERMES repositories"
  default     = "arn:aws:codestar-connections:us-east-1:351967858401:connection/4296e8d0-c3c9-4470-9d58-b955889ce226"
}
