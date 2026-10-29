// This file contains the configuration for the SDC AWS Pipeline

# demo is the lightweight end-to-end test mission. It exists to exercise the
# pipeline infrastructure with the real base-image, Lambda-image, and
# architecture builds, to give a baseline cost for one mission workspace, and
# to provide somewhere to develop features without touching a live mission.
# Keep it minimal: craft plus one science instrument, no concating, no Grafana,
# and no external secrets. Only the dev-demo workspace is intended to exist.

# AWS Deployment Region
# Region that the pipeline will be deployed to
deployment_region = "us-east-1"

# Mission Name
# This is the name of the mission that will be used to dynamically create the
# instrument buckets. It matches the demo mission in the swxsoc package's
# default configuration, which SWXSOC_MISSION=demo selects inside the Lambdas.
mission_name = "demo"

# Resource Purpose
# This is used for the Purpose tag on mission resources
resource_purpose = "SWxSOC demo mission pipeline test bed"

# Instrument Names Used in the Mission.
# craft is listed first by convention. myinst is the single science instrument;
# its name must match the instrument name of the demo mission in the swxsoc
# package configuration. Keep this order: the processing bucket notifications
# are indexed by list position.
instrument_names = ["craft", "myinst"]

# Valid Data Levels
# This is a list of the valid data levels for the mission
valid_data_levels = ["raw", "l0", "l1", "ql", "l2", "l3"]

# Timestream Database and Table Names for Logs
# The names of the timestream database and table that will be created to store logs
timestream_database_name      = "demo_sdc_aws_logs"
timestream_s3_logs_table_name = "demo_sdc_aws_s3_bucket_log_table"

# S3 Instrument Bucket Name
# The names of the buckets that will be created for the mission
incoming_bucket_name = "demo-swsoc-incoming"

# Concating Lambda Function Setup?
# The demo mission has no concating step. Turning this on adds the concating
# ECR repository and, with enable_concating_lambda, the Lambda.
needs_concating = false

# S3 Sorting Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the sorting lambda image
sorting_function_private_ecr_name = "demo_sdc_aws_sorting_lambda"

# S3 Artifacts Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the artifacts lambda image
artifacts_function_private_ecr_name = "demo_sdc_aws_artifacts_lambda"

# S3 Server Access Logs Bucket
# Only created in a prod-* workspace, which the demo mission does not use.
s3_server_access_logs_bucket_name = "demo-swsoc-s3-server-access-logs"

# Processing Lambda ECR Repository Name
# The name of the ECR repository that will be created to store the processing lambda image
processing_function_private_ecr_name = "demo_sdc_aws_processing_lambda"

# Concating Lambda ECR Repository Name
# Unused while needs_concating is false; kept so enabling concating is one flag.
concating_function_private_ecr_name = "demo_sdc_aws_concating_lambda"

# Docker Base ECR Repository Name
# The Terraform workspace prefix creates dev-demo-swsoc-docker-lambda-base in
# dev. This is the <mission>-swsoc-docker-lambda-base name the Lambda image
# buildspecs derive for any mission without a special case.
docker_base_public_ecr_name = "demo-swsoc-docker-lambda-base"

## IAM Role for pushing to S3 Incoming Bucket
# No external uploader; files are dropped into the incoming bucket by hand.
optional_s3_uploader_role_arn  = ""
optional_s3_uploader_role_arns = []

# Grafana Secret
# The demo mission has no Grafana instance, so the processing Lambda gets an
# empty GRAFANA_API_KEY and no secret is read.
enable_grafana_secret = false

# Notifications
# No communications platform is configured, so no external secret has to exist
# before the first plan. The Sorting and Artifacts Lambdas log an error when
# the comms client cannot be built and carry on. To try notifications, create
# and tag swxsoc/dev/demo/communications/mattermost (see the README) and set
# comms_platform = "mattermost" and enable_mattermost = true.
comms_platform    = ""
enable_mattermost = false

# Lambda creation flags
# Nothing exists for demo yet. Keep every flag false for the first apply, which
# creates the buckets, topics, queues, ECR repositories, and database before
# any image exists. Flip each flag to true once its image has been pushed by
# the build_demo_* CodeBuild projects, and apply with the immutable
# *_image_tag variables.
enable_processing_lambda = false
enable_sorting_lambda    = false
enable_artifacts_lambda  = false
enable_concating_lambda  = false

# Nothing exists for demo yet, so there are no Lambda log groups to adopt.
# Keep this false through the applies that turn each Lambda on; Terraform
# creates the log groups then.
adopt_existing_lambda_log_groups = false

# Cost trims for a test mission: short log retention and quick expiry of
# overwritten object versions. The RDS instance (db.t4g.micro, 30 GB) is the
# only fixed cost of note and is already the smallest class the root creates.
lambda_log_retention_days             = 14
s3_noncurrent_version_expiration_days = 7

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
