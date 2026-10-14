# Production-only resources depend on the workspace name, so this file runs
# separately under a prod-* workspace:
#   TF_WORKSPACE=prod-test terraform test -filter=production.tftest.hcl
mock_provider "aws" {
  # Mattermost credentials are intentionally derived from a data source. Make
  # mocked computed values available while planning so environment assertions
  # remain deterministic.
  override_during = plan

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-lambda-role"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock-lambda-policy"
    }
  }
}

run "plan_production_pipeline" {
  command = plan

  variables {
    deployment_region                    = "us-east-1"
    mission_name                         = "swxsoc_pipeline"
    instrument_names                     = ["reach"]
    include_craft_instrument             = false
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
    comms_platform                       = "mattermost"
    enable_mattermost                    = true
    enable_processing_lambda             = false
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = false
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    sf_image_tag                         = "test-immutable-sha"
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
    target = data.aws_secretsmanager_secret.mattermost[0]
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/prod/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/prod/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Production"
        ManagedBy   = "external"
        Mission     = "swxsoc_pipeline"
        Service     = "communications"
      }
    }
  }

  override_data {
    target          = data.aws_secretsmanager_secret_version.mattermost[0]
    override_during = plan
    values = {
      secret_string = "{\"channel_id\":\"channel-123\",\"token\":\"token-123\"}"
    }
  }

  assert {
    condition     = local.is_production
    error_message = "Run this file under a prod-* workspace: TF_WORKSPACE=prod-test terraform test -filter=production.tftest.hcl"
  }

  assert {
    condition = (
      contains(keys(resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets), "access-logs") &&
      length(resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets) == length(resource.aws_s3_bucket_versioning.sdc_buckets) + 1
    )
    error_message = "Production should manage lifecycle rules for every mission bucket plus the access-log bucket."
  }

  assert {
    condition = alltrue([
      length([
        for rule in resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets["access-logs"].rule : rule
        if length(rule.noncurrent_version_expiration) > 0 && rule.noncurrent_version_expiration[0].noncurrent_days == 30
      ]) == 1,
      length([
        for rule in resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets["access-logs"].rule : rule
        if length(rule.expiration) > 0 && rule.expiration[0].expired_object_delete_marker == true &&
        length(rule.abort_incomplete_multipart_upload) > 0 && rule.abort_incomplete_multipart_upload[0].days_after_initiation == 7
      ]) == 1,
    ])
    error_message = "The production access-log bucket should get the same noncurrent-version expiry and cleanup rules as the mission buckets."
  }
}

run "reject_fractional_retention" {
  command = plan

  variables {
    deployment_region                     = "us-east-1"
    mission_name                          = "swxsoc_pipeline"
    instrument_names                      = ["reach"]
    include_craft_instrument              = false
    valid_data_levels                     = ["raw", "l0", "l1"]
    timestream_database_name              = "swxsoc_pipeline_sdc_aws_logs"
    timestream_s3_logs_table_name         = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                  = "swxsoc-pipeline-incoming"
    s3_server_access_logs_bucket_name     = "swxsoc-pipeline-s3-server-access-logs"
    sorting_function_private_ecr_name     = "swxsoc_pipeline_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name   = "swxsoc_pipeline_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name  = "swxsoc_pipeline_sdc_aws_processing_lambda"
    concating_function_private_ecr_name   = "swxsoc_pipeline_sdc_aws_concating_lambda"
    docker_base_public_ecr_name           = "swxsoc-pipeline-docker-lambda-base"
    needs_concating                       = true
    enable_grafana_secret                 = false
    comms_platform                        = "mattermost"
    enable_mattermost                     = true
    enable_processing_lambda              = false
    enable_sorting_lambda                 = true
    enable_artifacts_lambda               = false
    enable_concating_lambda               = false
    adopt_existing_lambda_log_groups      = false
    sf_image_tag                          = "test-immutable-sha"
    s3_noncurrent_version_expiration_days = 1.5
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
    target = data.aws_secretsmanager_secret.mattermost[0]
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/prod/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/prod/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Production"
        ManagedBy   = "external"
        Mission     = "swxsoc_pipeline"
        Service     = "communications"
      }
    }
  }

  override_data {
    target          = data.aws_secretsmanager_secret_version.mattermost[0]
    override_during = plan
    values = {
      secret_string = "{\"channel_id\":\"channel-123\",\"token\":\"token-123\"}"
    }
  }

  expect_failures = [
    var.s3_noncurrent_version_expiration_days,
  ]
}
