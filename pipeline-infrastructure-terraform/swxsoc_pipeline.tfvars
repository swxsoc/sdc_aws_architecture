// This file contains the configuration for the SDC AWS Pipeline

# AWS Deployment Region
# Region that the pipeline will be deployed to
deployment_region = "us-east-1"

# Mission Name
# This is the name of the mission that will be used to dynamically create the instrument buckets
mission_name = "swxsoc_pipeline"

# Instrument Names Used in the Mission.
# The names are used to dynamically create the instrument bucket
instrument_names = ["reach"]

# Valid Data Levels
# This is a list of the valid data levels for the mission
valid_data_levels = ["raw", "l0", "l1", "l2", "l3", "ql"]

# Timestream Database and Table Names for Logs
# The names of the timestream database and table that will be created to store logs
timestream_database_name      = "swxsoc_pipeline_sdc_aws_logs"
timestream_s3_logs_table_name = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"

# S3 Instrument Bucket Name
# The names of the buckets that will be created for the mission
incoming_bucket_name = "swxsoc-pipeline-incoming"

# Concating Lambda Function Setup?
# This variable controls whether the concating lambda function and related resources will be created
needs_concating = false

# S3 Sorting Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the sorting lambda image
sorting_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_sorting_lambda"

# S3 Artifacts Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the artifacts lambda image
artifacts_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_artifacts_lambda"

# S3 Server Access Logs Bucket
# The name of the bucket that will be created to store the s3 server access logs
s3_server_access_logs_bucket_name = "swxsoc-pipeline-s3-server-access-logs"

# Processing Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the processing lambda image
processing_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_processing_lambda"

# Concating Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the concating lambda image
concating_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_concating_lambda"

# Docker Base ECR Repository Name
# The name of the ECR repository that will be created to store the docker base image
docker_base_public_ecr_name = "swxsoc-pipeline-docker-lambda-base"

## IAM Role for pushing to S3 Incoming Bucket
# The name of the IAM role from the other account that will be used to push to the incoming bucket
optional_s3_uploader_role_arn  = ""
optional_s3_uploader_role_arns = []

# Grafana Secret (optional for swxsoc_pipeline)
enable_grafana_secret = false
grafana_secret_name   = "swxsoc-pipeline-grafana-credentials"

# Lambda creation flags (enable once images exist)
enable_processing_lambda = false
enable_sorting_lambda    = false
enable_artifacts_lambda  = false
enable_concating_lambda  = false

# Lambda VPC settings (match existing default subnets; update if needed)
lambda_vpc_subnet_ids = ["subnet-0972d4965ef8eb1e8", "subnet-0e24325c69b9a1f74"]

# RDS ingress allowlists (empty for swxsoc_pipeline to avoid missing SG/CIDR)
rds_additional_security_group_ids = []
rds_ingress_cidr_blocks           = []

# RDS engine version (must exist in target region)
rds_engine_version = "14.21"

# Safe placeholder images so first apply succeeds before mission images are pushed
processing_image_uri_override = "public.ecr.aws/lambda/python:3.11"
sorting_image_uri_override    = "public.ecr.aws/lambda/python:3.11"
artifacts_image_uri_override  = "public.ecr.aws/lambda/python:3.11"
concating_image_uri_override  = "public.ecr.aws/lambda/python:3.11"
