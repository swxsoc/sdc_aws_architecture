// This file contains the configuration for the SDC AWS Pipeline

# AWS Deployment Region
# Region that the pipeline will be deployed to
deployment_region = "us-east-1"

# Mission Name
# This is the name of the mission that will be used to dynamically create the instrument buckets
soc_name = "swxsoc"

# S3 Executor Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the artifacts lambda image
executor_function_private_ecr_name = "swxsoc_sdc_aws_executor_lambda"


# Timestream Database and Table Names for Logs
# The names of the timestream database and table that will be created to store logs
timestream_database_name      = "swxsoc_sdc_aws_logs"
timestream_measures_table_name = "swxsoc_measures_table"