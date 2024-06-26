// This file contains the configuration for the SDC AWS Pipeline

# AWS Deployment Region
# Region that the pipeline will be deployed to
deployment_region = "us-east-1"

# Mission Name
# This is the name of the mission that will be used to dynamically create the instrument buckets
mission_name = "padre"

# Instrument Names Used in the Mission. 
# The names are used to dynamically create the instrument bucket
instrument_names = ["meddea", "sharp"]

# Valid Data Levels
# This is a list of the valid data levels for the mission
valid_data_levels = ["l0", "l1", "ql"]

# Timestream Database and Table Names for Logs
# The names of the timestream database and table that will be created to store logs
timestream_database_name      = "padre_sdc_aws_logs"
timestream_s3_logs_table_name = "padre_sdc_aws_s3_bucket_log_table"

# S3 Instrument Bucket Name
# The names of the buckets that will be created for the mission
incoming_bucket_name = "padre-swsoc-incoming"

# S3 Sorting Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the sorting lambda image
sorting_function_private_ecr_name = "padre_sdc_aws_sorting_lambda"

# S3 Artifacts Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the artifacts lambda image
artifacts_function_private_ecr_name = "padre_sdc_aws_artifacts_lambda"

# S3 Server Access Logs Bucket
# The name of the bucket that will be created to store the s3 server access logs
s3_server_access_logs_bucket_name = "padre-swsoc-s3-server-access-logs"

# Processing Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the processing lambda image
processing_function_private_ecr_name = "padre_sdc_aws_processing_lambda"

# Docker Base ECR Repository Name
# The name of the ECR repository that will be created to store the docker base image
docker_base_public_ecr_name = "padre-swsoc-docker-lambda-base"