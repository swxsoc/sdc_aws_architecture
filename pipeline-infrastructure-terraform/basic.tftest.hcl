mock_provider "aws" {}

run "plan_pipeline" {
  command = plan

  variables {
    deployment_region                    = "us-east-1"
    mission_name                         = "swxsoc_pipeline"
    instrument_names                     = ["reach"]
    valid_data_levels                    = ["raw", "l0", "l1"]
    timestream_database_name             = "swxsoc_pipeline_sdc_aws_logs"
    timestream_s3_logs_table_name        = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                 = "swxsoc-pipeline-incoming"
    s3_server_access_logs_bucket_name    = "swxsoc-pipeline-s3-server-access-logs"
    sorting_function_private_ecr_name    = "swxsoc_pipeline_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name  = "swxsoc_pipeline_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_processing_lambda"
    concating_function_private_ecr_name  = "swxsoc_pipeline_sdc_aws_concating_lambda"
    docker_base_public_ecr_name          = "swxsoc-pipeline-docker-lambda-base"
    needs_concating                      = true
    enable_grafana_secret                = false
    enable_mattermost                    = true
    enable_processing_lambda             = false
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = false
    enable_concating_lambda              = false
  }

  override_data {
    target = data.aws_vpc.default
    values = {
      id = "vpc-123456"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = data.aws_secretsmanager_secret.mattermost
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
    }
  }

  override_data {
    target = data.aws_secretsmanager_secret_version.mattermost
    values = {
      secret_string = "{\"channel_id\":\"channel-123\",\"token\":\"token-123\"}"
    }
  }

  assert {
    condition     = resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-incoming"].bucket == "dev-swxsoc-pipeline-incoming"
    error_message = "Incoming bucket name should be mission-scoped and prefixed for dev."
  }

  assert {
    condition     = resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].bucket == "dev-swxsoc-pipeline-reach"
    error_message = "Instrument bucket name should use hyphenated mission prefix."
  }

  assert {
    condition = (
      resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].tags["Mission"] == "swxsoc_pipeline" &&
      resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].tags["Service"] == "sdc-aws-pipeline"
    )
    error_message = "Pipeline resources should include the required Mission and Service tags."
  }

  assert {
    condition = alltrue([
      jsondecode(resource.aws_ecr_lifecycle_policy.processing_function_private_ecr.policy).rules[0].selection.countNumber == 15,
      jsondecode(resource.aws_ecr_lifecycle_policy.concating_function_private_ecr[0].policy).rules[0].selection.countNumber == 15,
      jsondecode(resource.aws_ecr_lifecycle_policy.sorting_function_private_ecr.policy).rules[0].selection.countNumber == 15,
      jsondecode(resource.aws_ecr_lifecycle_policy.artifacts_function_private_ecr.policy).rules[0].selection.countNumber == 15
    ])
    error_message = "Pipeline ECR lifecycle policies should retain the newest 15 images."
  }

  assert {
    condition     = resource.aws_secretsmanager_secret.rds_secret.name == "swxsoc/dev/swxsoc-pipeline/processing/rds"
    error_message = "Pipeline secrets should use the environment/mission/service path convention."
  }

  assert {
    condition     = resource.aws_secretsmanager_secret.rds_secret.tags["Service"] == "processing"
    error_message = "Pipeline secrets should be tagged with their consuming service."
  }
}

run "plan_swxsoc_artifacts_lambda" {
  command = plan

  variables {
    deployment_region                    = "us-east-1"
    mission_name                         = "swxsoc_pipeline"
    instrument_names                     = ["reach"]
    valid_data_levels                    = ["raw", "l0", "l1"]
    timestream_database_name             = "swxsoc_pipeline_sdc_aws_logs"
    timestream_s3_logs_table_name        = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                 = "swxsoc-pipeline-incoming"
    s3_server_access_logs_bucket_name    = "swxsoc-pipeline-s3-server-access-logs"
    sorting_function_private_ecr_name    = "swxsoc_pipeline_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name  = "swxsoc_pipeline_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_processing_lambda"
    concating_function_private_ecr_name  = "swxsoc_pipeline_sdc_aws_concating_lambda"
    docker_base_public_ecr_name          = "swxsoc-pipeline-docker-lambda-base"
    needs_concating                      = false
    enable_grafana_secret                = false
    enable_mattermost                    = true
    enable_processing_lambda             = false
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = true
    enable_concating_lambda              = false
    artifacts_image_uri_override         = ""
  }

  override_data {
    target = data.aws_vpc.default
    values = {
      id = "vpc-123456"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = data.aws_secretsmanager_secret.mattermost
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
    }
  }

  override_data {
    target = data.aws_secretsmanager_secret_version.mattermost
    values = {
      secret_string = "{\"channel_id\":\"channel-123\",\"token\":\"token-123\"}"
    }
  }

  assert {
    condition     = length(resource.aws_lambda_function.aws_sdc_artifacts_lambda_function) == 1
    error_message = "Artifacts Lambda should be planned when enable_artifacts_lambda is true."
  }

  assert {
    condition     = length(resource.aws_sns_topic_subscription.af_sns_topic_subscription) == 1
    error_message = "Artifacts Lambda should subscribe to each instrument SNS topic."
  }

  assert {
    condition = (
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["COMMS_PLATFORM"] == "mattermost" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["MATTERMOST_CHANNEL_ID"] == "channel-123" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["MATTERMOST_TOKEN"] == "token-123" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["MATTERMOST_URL"] == "https://mm.sciencecloud.nasa.gov:443"
    )
    error_message = "Sorting Lambda should receive the complete Mattermost environment."
  }

  assert {
    condition = (
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].environment[0].variables["COMMS_PLATFORM"] == "mattermost" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].environment[0].variables["MATTERMOST_CHANNEL_ID"] == "channel-123" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].environment[0].variables["MATTERMOST_TOKEN"] == "token-123" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].environment[0].variables["MATTERMOST_URL"] == "https://mm.sciencecloud.nasa.gov:443"
    )
    error_message = "Artifacts Lambda should receive the complete Mattermost environment."
  }

}
