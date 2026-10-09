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

run "plan_pipeline" {
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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
      resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].tags["Service"] == "sdc-aws-pipeline" &&
      resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].tags["Environment"] == "Development" &&
      resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].tags["ManagedBy"] == "terraform" &&
      resource.aws_s3_bucket.sdc_buckets["swxsoc-pipeline-reach"].tags["Project"] == "swxsoc_pipeline"
    )
    error_message = "Shared pipeline resources should include the complete common tags."
  }

  assert {
    condition = (
      resource.aws_ecr_repository.processing_function_private_ecr.tags["Service"] == "processing" &&
      resource.aws_ecr_repository.sorting_function_private_ecr.tags["Service"] == "sorting" &&
      resource.aws_ecr_repository.artifacts_function_private_ecr.tags["Service"] == "artifacts" &&
      resource.aws_ecr_repository.concating_function_private_ecr[0].tags["Service"] == "concating" &&
      resource.aws_ecrpublic_repository.docker_base_public_ecr.tags["Service"] == "container-base"
    )
    error_message = "Each ECR repository should identify its component service."
  }

  assert {
    condition = (
      resource.aws_lambda_function.sorting_lambda_function[0].tags["Mission"] == "swxsoc_pipeline" &&
      resource.aws_lambda_function.sorting_lambda_function[0].tags["Service"] == "sorting" &&
      resource.aws_lambda_function.sorting_lambda_function[0].tags["Environment"] == "Development" &&
      resource.aws_lambda_function.sorting_lambda_function[0].tags["ManagedBy"] == "terraform"
    )
    error_message = "Sorting Lambda should include the complete common and component tags."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_log_group.sorting[0].retention_in_days == 90 &&
      resource.aws_cloudwatch_log_group.sorting[0].tags["Mission"] == "swxsoc_pipeline" &&
      resource.aws_cloudwatch_log_group.sorting[0].tags["Service"] == "sorting"
    )
    error_message = "Sorting logs should be explicitly retained and tagged."
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
    condition = (
      length(resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets) == length(resource.aws_s3_bucket_versioning.sdc_buckets) &&
      alltrue([
        for config in resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets :
        length([for rule in config.rule : rule if length(rule.noncurrent_version_expiration) > 0 && rule.noncurrent_version_expiration[0].noncurrent_days == 30]) == 1
      ])
    )
    error_message = "Every versioned mission bucket should expire noncurrent object versions after 30 days."
  }

  assert {
    condition = alltrue([
      for config in resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets :
      length([
        for rule in config.rule : rule
        if length(rule.expiration) > 0 && rule.expiration[0].expired_object_delete_marker == true &&
        length(rule.abort_incomplete_multipart_upload) > 0 && rule.abort_incomplete_multipart_upload[0].days_after_initiation == 7
      ]) == 1
    ])
    error_message = "Every versioned mission bucket should clear expired delete markers and abort multipart uploads after 7 days."
  }

  assert {
    condition     = !contains(keys(resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets), "access-logs")
    error_message = "Development workspaces have no access-log bucket, so they should have no access-log lifecycle configuration."
  }

  assert {
    condition     = resource.aws_secretsmanager_secret.rds_secret.name == "swxsoc/dev/swxsoc-pipeline/processing/rds"
    error_message = "Pipeline secrets should use the environment/mission/service path convention."
  }

  assert {
    condition = (
      resource.aws_secretsmanager_secret.rds_secret.tags["Service"] == "processing" &&
      resource.aws_secretsmanager_secret.rds_secret.tags["Environment"] == "Development" &&
      resource.aws_secretsmanager_secret.rds_secret.tags["ManagedBy"] == "terraform" &&
      resource.aws_secretsmanager_secret.rds_secret.recovery_window_in_days == 30
    )
    error_message = "Pipeline secrets should have complete tags and a recoverable deletion window."
  }

  assert {
    condition     = resource.aws_db_instance.rds_instance.identifier == "dev-swxsoc-pipeline-cdftracker-db"
    error_message = "RDS should use a deterministic environment/mission identifier."
  }
}

run "plan_swxsoc_artifacts_lambda" {
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
    needs_concating                      = false
    enable_grafana_secret                = false
    comms_platform                       = "mattermost"
    enable_mattermost                    = true
    enable_processing_lambda             = false
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = true
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    sf_image_tag                         = "test-immutable-sha"
    af_image_tag                         = "test-immutable-sha"
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
    target = data.aws_secretsmanager_secret.mattermost[0]
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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

  assert {
    condition = (
      resource.aws_lambda_function.sorting_lambda_function[0].tags["Service"] == "sorting" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].tags["Service"] == "artifacts" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].tags["Environment"] == "Development" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].tags["ManagedBy"] == "terraform"
    )
    error_message = "Sorting and Artifacts Lambdas should use component service tags."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_log_group.sorting[0].tags["Service"] == "sorting" &&
      resource.aws_cloudwatch_log_group.artifacts[0].tags["Service"] == "artifacts"
    )
    error_message = "Sorting and Artifacts log groups should use component service tags."
  }

}

run "plan_processing_extra_environment" {
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
    needs_concating                      = false
    enable_grafana_secret                = false
    comms_platform                       = "mattermost"
    enable_mattermost                    = true
    enable_processing_lambda             = true
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = true
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    sf_image_tag                         = "test-immutable-sha"
    af_image_tag                         = "test-immutable-sha"
    pf_image_tag                         = "test-immutable-sha"
    artifacts_image_uri_override         = ""
    processing_extra_environment = {
      CARTOPY_DATA_DIR = "/tmp/cartopy"
      HOME             = "/tmp"
    }
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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
    condition = (
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["CARTOPY_DATA_DIR"] == "/tmp/cartopy" &&
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["HOME"] == "/tmp" &&
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["SWXSOC_MISSION"] == "swxsoc_pipeline" &&
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["SPACEPY"] == "/tmp"
    )
    error_message = "processing_extra_environment should be added to the processing Lambda alongside the managed variables."
  }
}

run "reject_processing_extra_environment_override" {
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
    needs_concating                      = false
    enable_grafana_secret                = false
    comms_platform                       = "mattermost"
    enable_mattermost                    = true
    enable_processing_lambda             = true
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = true
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    sf_image_tag                         = "test-immutable-sha"
    af_image_tag                         = "test-immutable-sha"
    pf_image_tag                         = "test-immutable-sha"
    artifacts_image_uri_override         = ""
    processing_extra_environment = {
      SWXSOC_MISSION = "someone-else"
    }
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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
    var.processing_extra_environment,
  ]
}

run "reject_adopting_unlisted_instrument" {
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
    adopt_existing_instruments           = ["craft"]
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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
    var.adopt_existing_instruments,
  ]
}

run "craft_is_appended_by_default" {
  command = plan

  variables {
    deployment_region                    = "us-east-1"
    mission_name                         = "swxsoc_pipeline"
    instrument_names                     = ["meddea", "sharp"]
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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
    condition     = local.instrument_names == tolist(["meddea", "sharp", "craft"])
    error_message = "craft should be appended after the mission's own instruments by default."
  }

  assert {
    condition     = contains(keys(resource.aws_sns_topic.sns_topics), "swxsoc-pipeline-craft")
    error_message = "The default craft instrument should get the standard per-instrument resources."
  }
}

run "listed_craft_keeps_its_position" {
  command = plan

  variables {
    deployment_region                    = "us-east-1"
    mission_name                         = "swxsoc_pipeline"
    instrument_names                     = ["craft", "iaxis", "ifire"]
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      id  = "swxsoc/dev/swxsoc-pipeline/communications/mattermost"
      tags = {
        Environment = "Development"
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
    condition     = local.instrument_names == tolist(["craft", "iaxis", "ifire"])
    error_message = "A mission that already lists craft must keep its existing order."
  }
}
