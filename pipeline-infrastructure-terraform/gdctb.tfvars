// This file contains the configuration for the SDC AWS Pipeline

# AWS Deployment Region
# Region that the pipeline will be deployed to
deployment_region = "us-east-1"

# Mission Name
# This is the name of the mission that will be used to dynamically create the instrument buckets
mission_name = "gdctb"

# Resource Purpose
# This is used for the Purpose tag on mission resources
resource_purpose = "GDC Trailblazer GDCTB mission"

# Instrument Names Used in the Mission.
# The names are used to dynamically create the instrument buckets and match
# the gdctb instrument names in the swxsoc package configuration.
# craft is listed first by convention (as in iMPAX); a listed craft keeps its
# position instead of being appended. Keep this order: the processing bucket
# notifications are indexed by list position.
instrument_names = ["craft", "cape-eea"]

# Valid Data Levels
# This is a list of the valid data levels for the mission
valid_data_levels = ["raw", "l0", "l1", "ql", "l2", "l3"]

# Timestream Database and Table Names for Logs
# The names of the timestream database and table that will be created to store logs
timestream_database_name      = "gdctb_sdc_aws_logs"
timestream_s3_logs_table_name = "gdctb_sdc_aws_s3_bucket_log_table"

# S3 Instrument Bucket Name
# The names of the buckets that will be created for the mission
incoming_bucket_name = "gdctb-swsoc-incoming"

# Concating Lambda Function Setup?
# This variable controls whether the concating lambda function and related resources will be created
needs_concating = true

# S3 Sorting Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the sorting lambda image
sorting_function_private_ecr_name = "gdctb_sdc_aws_sorting_lambda"

# S3 Artifacts Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the artifacts lambda image
artifacts_function_private_ecr_name = "gdctb_sdc_aws_artifacts_lambda"

# S3 Server Access Logs Bucket
# The name of the bucket that will be created to store the s3 server access logs
s3_server_access_logs_bucket_name = "gdctb-swsoc-s3-server-access-logs"

# Processing Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the processing lambda image
processing_function_private_ecr_name = "gdctb_sdc_aws_processing_lambda"

# Concating Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the concating lambda image
concating_function_private_ecr_name = "gdctb_sdc_aws_concating_lambda"

# Docker Base ECR Repository Name
# The Terraform workspace prefix creates dev-gdctb-swsoc-docker-lambda-base in dev.
# This matches the IMAGE_NAME the GDC-Trailblazer base image buildspec pushes.
docker_base_public_ecr_name = "gdctb-swsoc-docker-lambda-base"

## IAM Role for pushing to S3 Incoming Bucket
# The name of the IAM role from the other account that will be used to push to the incoming bucket
optional_s3_uploader_role_arn  = ""
optional_s3_uploader_role_arns = []

# Grafana Secret
# The processing Lambda reads its Grafana API key from
# swxsoc/<environment>/gdctb/processing/grafana. Set this to true once that
# secret exists for the GDCTB Grafana instance.
enable_grafana_secret = false

# Mattermost notifications for Sorting and Artifacts. The token and channel ID
# come from swxsoc/<environment>/gdctb/communications/mattermost, which must be
# created and tagged (Mission=gdctb, Service=communications,
# Environment=Development|Production, ManagedBy=external) before the first
# plan in each workspace.
comms_platform    = "mattermost"
enable_mattermost = true
mattermost_url    = "https://mm.sciencecloud.nasa.gov:443"

# Lambda creation flags
# The mission is new, so the first apply creates the buckets, topics, queues,
# ECR repositories, and database before any image exists. Set each flag to
# true once its image has been pushed by the gdctb CodeBuild projects.
enable_processing_lambda = false
enable_sorting_lambda    = false
enable_artifacts_lambda  = false
enable_concating_lambda  = false

# Nothing exists for gdctb yet, so there are no Lambda log groups to adopt.
# Keep this false through the applies that turn each Lambda on; Terraform
# creates the log groups then. Remove it only once every enabled Lambda's log
# group exists in both workspaces, or the import of a missing group fails the
# plan.
adopt_existing_lambda_log_groups = false

# Lambda VPC settings
lambda_vpc_subnet_ids = ["subnet-0972d4965ef8eb1e8", "subnet-0e24325c69b9a1f74"]

# RDS ingress allowlists
rds_additional_security_group_ids = ["sg-002dbe7887ac759c5"] # Grafana EC2 webDMZ
rds_ingress_cidr_blocks           = []

# RDS engine version (must exist in target region)
rds_engine_version = "14.21"

# Mission images come from the private ECR repositories. CodeBuild supplies
# immutable *_image_tag values. A manual apply must pass those tag variables
# explicitly; do not deploy the mutable `latest` defaults.
processing_image_uri_override = ""
sorting_image_uri_override    = ""
artifacts_image_uri_override  = ""
concating_image_uri_override  = ""
