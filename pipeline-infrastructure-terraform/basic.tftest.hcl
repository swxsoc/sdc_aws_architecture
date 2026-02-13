mock_provider "aws" {}

run "plan_pipeline" {
  command = plan

  providers = {
    aws = mock.aws
  }

  variables {
    deployment_region                   = "us-east-1"
    mission_name                        = "swxsoc_pipeline"
    instrument_names                    = ["reach"]
    valid_data_levels                   = ["raw", "l0", "l1"]
    timestream_database_name            = "swxsoc_pipeline_sdc_aws_logs"
    timestream_s3_logs_table_name       = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                = "swxsoc-pipeline-incoming"
    s3_server_access_logs_bucket_name   = "swxsoc-pipeline-s3-server-access-logs"
    sorting_function_private_ecr_name   = "swxsoc_pipeline_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name = "swxsoc_pipeline_sdc_aws_processing_lambda"
    concating_function_private_ecr_name  = "swxsoc_pipeline_sdc_aws_concating_lambda"
    docker_base_public_ecr_name         = "swxsoc-pipeline-docker-lambda-base"
    needs_concating                     = false
    enable_grafana_secret               = false
    enable_processing_lambda            = false
    enable_sorting_lambda               = false
    enable_artifacts_lambda             = false
    enable_concating_lambda             = false
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
    target = data.aws_subnets.public_subnets
    values = {
      ids = []
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
}
