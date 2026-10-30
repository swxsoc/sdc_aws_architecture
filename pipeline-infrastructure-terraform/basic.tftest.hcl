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

# gdctb.tfvars bootstraps a brand-new mission: every Lambda is disabled until
# its image exists, craft is listed first by convention, and nothing is adopted.
run "plan_gdctb_bootstrap" {
  command = plan

  variables {
    deployment_region                    = "us-east-1"
    mission_name                         = "gdctb"
    resource_purpose                     = "GDC Trailblazer GDCTB mission"
    instrument_names                     = ["craft", "cape-eea"]
    valid_data_levels                    = ["raw", "l0", "l1", "ql", "l2", "l3"]
    timestream_database_name             = "gdctb_sdc_aws_logs"
    timestream_s3_logs_table_name        = "gdctb_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                 = "gdctb-swsoc-incoming"
    s3_server_access_logs_bucket_name    = "gdctb-swsoc-s3-server-access-logs"
    sorting_function_private_ecr_name    = "gdctb_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name  = "gdctb_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name = "gdctb_sdc_aws_processing_lambda"
    concating_function_private_ecr_name  = "gdctb_sdc_aws_concating_lambda"
    docker_base_public_ecr_name          = "gdctb-swsoc-docker-lambda-base"
    needs_concating                      = true
    enable_grafana_secret                = false
    comms_platform                       = "mattermost"
    enable_mattermost                    = true
    enable_processing_lambda             = false
    enable_sorting_lambda                = false
    enable_artifacts_lambda              = false
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    rds_engine_version                   = "14.21"
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/gdctb/communications/mattermost"
      id  = "swxsoc/dev/gdctb/communications/mattermost"
      tags = {
        Environment = "Development"
        ManagedBy   = "external"
        Mission     = "gdctb"
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
    condition     = local.instrument_names == tolist(["craft", "cape-eea"])
    error_message = "GDCTB lists craft first by convention, and a listed craft keeps its position."
  }

  assert {
    condition = (
      resource.aws_s3_bucket.sdc_buckets["gdctb-swsoc-incoming"].bucket == "dev-gdctb-swsoc-incoming" &&
      resource.aws_s3_bucket.sdc_buckets["gdctb-cape-eea"].bucket == "dev-gdctb-cape-eea" &&
      resource.aws_s3_bucket.sdc_buckets["gdctb-craft"].bucket == "dev-gdctb-craft" &&
      resource.aws_s3_bucket.sdc_buckets["gdctb-cape-eea"].tags["Mission"] == "gdctb" &&
      resource.aws_s3_bucket.sdc_buckets["gdctb-cape-eea"].tags["Purpose"] == "GDC Trailblazer GDCTB mission"
    )
    error_message = "GDCTB buckets should be named from the mission prefix and hyphenated instrument names."
  }

  assert {
    condition = (
      contains(keys(resource.aws_sns_topic.sns_topics), "gdctb-cape-eea") &&
      contains(keys(resource.aws_sns_topic.sns_topics), "gdctb-craft") &&
      contains(keys(resource.aws_sqs_queue.sqs_queue), "gdctb-cape-eea") &&
      contains(keys(resource.aws_sqs_queue.sqs_queue), "gdctb-craft")
    )
    error_message = "Each GDCTB instrument should get its SNS topic and SQS queue."
  }

  assert {
    condition = (
      resource.aws_ecr_repository.processing_function_private_ecr.name == "dev-gdctb_sdc_aws_processing_lambda" &&
      resource.aws_ecr_repository.sorting_function_private_ecr.name == "dev-gdctb_sdc_aws_sorting_lambda" &&
      resource.aws_ecr_repository.artifacts_function_private_ecr.name == "dev-gdctb_sdc_aws_artifacts_lambda" &&
      resource.aws_ecr_repository.concating_function_private_ecr[0].name == "dev-gdctb_sdc_aws_concating_lambda" &&
      resource.aws_ecrpublic_repository.docker_base_public_ecr.repository_name == "dev-gdctb-swsoc-docker-lambda-base"
    )
    error_message = "GDCTB ECR repositories should match the names the GDC-Trailblazer buildspecs push to, including concating."
  }

  assert {
    condition = (
      length(resource.aws_lambda_function.aws_sdc_processing_lambda_function) == 0 &&
      length(resource.aws_lambda_function.sorting_lambda_function) == 0 &&
      length(resource.aws_lambda_function.aws_sdc_artifacts_lambda_function) == 0 &&
      length(resource.aws_lambda_function.aws_sdc_concating_lambda_function) == 0
    )
    error_message = "The GDCTB bootstrap plan must not create any Lambda before its image exists."
  }

  assert {
    condition = (
      resource.aws_secretsmanager_secret.rds_secret.name == "swxsoc/dev/gdctb/processing/rds" &&
      resource.aws_db_instance.rds_instance.identifier == "dev-gdctb-cdftracker-db"
    )
    error_message = "GDCTB secrets and database should follow the mission-first naming convention."
  }
}

# demo.tfvars is the lightweight test mission: craft plus one science
# instrument, no concating, no Grafana, no communications secret, short log
# retention, and every Lambda disabled until its image exists.
run "plan_demo_bootstrap" {
  command = plan

  variables {
    deployment_region                     = "us-east-1"
    mission_name                          = "demo"
    resource_purpose                      = "SWxSOC demo mission pipeline test bed"
    instrument_names                      = ["craft", "myinst"]
    valid_data_levels                     = ["raw", "l0", "l1", "ql", "l2", "l3"]
    timestream_database_name              = "demo_sdc_aws_logs"
    timestream_s3_logs_table_name         = "demo_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                  = "demo-swsoc-incoming"
    s3_server_access_logs_bucket_name     = "demo-swsoc-s3-server-access-logs"
    sorting_function_private_ecr_name     = "demo_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name   = "demo_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name  = "demo_sdc_aws_processing_lambda"
    concating_function_private_ecr_name   = "demo_sdc_aws_concating_lambda"
    docker_base_public_ecr_name           = "demo-swsoc-docker-lambda-base"
    needs_concating                       = false
    enable_grafana_secret                 = false
    comms_platform                        = "mattermost"
    enable_mattermost                     = true
    enable_processing_lambda              = false
    enable_sorting_lambda                 = false
    enable_artifacts_lambda               = false
    enable_concating_lambda               = false
    adopt_existing_lambda_log_groups      = false
    lambda_log_retention_days             = 14
    s3_noncurrent_version_expiration_days = 7
    rds_engine_version                    = "14.21"
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/demo/communications/mattermost"
      id  = "swxsoc/dev/demo/communications/mattermost"
      tags = {
        Environment = "Development"
        ManagedBy   = "external"
        Mission     = "demo"
        Service     = "communications"
      }
    }
  }

  override_data {
    target          = data.aws_secretsmanager_secret_version.mattermost[0]
    override_during = plan
    values = {
      secret_string = "{\"channel_id\":\"demo-channel-123\",\"token\":\"demo-token-123\"}"
    }
  }

  assert {
    condition     = local.instrument_names == tolist(["craft", "myinst"])
    error_message = "The demo mission lists craft first and one science instrument."
  }

  assert {
    condition = (
      resource.aws_s3_bucket.sdc_buckets["demo-swsoc-incoming"].bucket == "dev-demo-swsoc-incoming" &&
      resource.aws_s3_bucket.sdc_buckets["demo-craft"].bucket == "dev-demo-craft" &&
      resource.aws_s3_bucket.sdc_buckets["demo-myinst"].bucket == "dev-demo-myinst" &&
      length(resource.aws_s3_bucket.sdc_buckets) == 3 &&
      resource.aws_s3_bucket.sdc_buckets["demo-myinst"].tags["Mission"] == "demo" &&
      resource.aws_s3_bucket.sdc_buckets["demo-myinst"].tags["Purpose"] == "SWxSOC demo mission pipeline test bed"
    )
    error_message = "The demo mission should create exactly the incoming, craft, and myinst buckets with demo tags."
  }

  assert {
    condition = alltrue([
      for configuration in resource.aws_s3_bucket_lifecycle_configuration.versioned_buckets :
      configuration.rule[0].noncurrent_version_expiration[0].noncurrent_days == 7
    ])
    error_message = "The demo buckets should expire noncurrent object versions after 7 days."
  }

  assert {
    condition = (
      length(resource.aws_ecr_repository.concating_function_private_ecr) == 0 &&
      resource.aws_ecr_repository.processing_function_private_ecr.name == "dev-demo_sdc_aws_processing_lambda" &&
      resource.aws_ecrpublic_repository.docker_base_public_ecr.repository_name == "dev-demo-swsoc-docker-lambda-base"
    )
    error_message = "The demo mission should get the three Lambda repositories and the base repository the image buildspecs derive, and no concating repository."
  }

  assert {
    condition = (
      local.mattermost_secret_name == "swxsoc/dev/demo/communications/mattermost" &&
      length(data.aws_secretsmanager_secret.mattermost) == 1 &&
      length(data.aws_secretsmanager_secret.grafana) == 0
    )
    error_message = "The demo mission reads exactly one external secret, the dev-demo Mattermost secret at the mission-first path, and no Grafana secret."
  }

  assert {
    condition = (
      length(resource.aws_lambda_function.aws_sdc_processing_lambda_function) == 0 &&
      length(resource.aws_lambda_function.sorting_lambda_function) == 0 &&
      length(resource.aws_lambda_function.aws_sdc_artifacts_lambda_function) == 0 &&
      length(resource.aws_lambda_function.aws_sdc_concating_lambda_function) == 0
    )
    error_message = "The demo bootstrap plan must not create any Lambda before its image exists."
  }

  assert {
    condition = (
      resource.aws_secretsmanager_secret.rds_secret.name == "swxsoc/dev/demo/processing/rds" &&
      resource.aws_db_instance.rds_instance.identifier == "dev-demo-cdftracker-db" &&
      resource.aws_db_instance.rds_instance.instance_class == "db.t4g.micro"
    )
    error_message = "The demo database should follow the mission-first naming convention on the smallest instance class."
  }
}

# With an image pushed, a demo Lambda posts to the demo Mattermost channel
# from the dev-demo secret and keeps the shorter log retention.
run "plan_demo_sorting_with_mattermost" {
  command = plan

  variables {
    deployment_region                     = "us-east-1"
    mission_name                          = "demo"
    instrument_names                      = ["craft", "myinst"]
    valid_data_levels                     = ["raw", "l0", "l1", "ql", "l2", "l3"]
    timestream_database_name              = "demo_sdc_aws_logs"
    timestream_s3_logs_table_name         = "demo_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                  = "demo-swsoc-incoming"
    s3_server_access_logs_bucket_name     = "demo-swsoc-s3-server-access-logs"
    sorting_function_private_ecr_name     = "demo_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name   = "demo_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name  = "demo_sdc_aws_processing_lambda"
    docker_base_public_ecr_name           = "demo-swsoc-docker-lambda-base"
    needs_concating                       = false
    enable_grafana_secret                 = false
    comms_platform                        = "mattermost"
    enable_mattermost                     = true
    enable_processing_lambda              = false
    enable_sorting_lambda                 = true
    enable_artifacts_lambda               = false
    enable_concating_lambda               = false
    adopt_existing_lambda_log_groups      = false
    lambda_log_retention_days             = 14
    s3_noncurrent_version_expiration_days = 7
    sf_image_tag                          = "test-immutable-sha"
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
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:swxsoc/dev/demo/communications/mattermost"
      id  = "swxsoc/dev/demo/communications/mattermost"
      tags = {
        Environment = "Development"
        ManagedBy   = "external"
        Mission     = "demo"
        Service     = "communications"
      }
    }
  }

  override_data {
    target          = data.aws_secretsmanager_secret_version.mattermost[0]
    override_during = plan
    values = {
      secret_string = "{\"channel_id\":\"demo-channel-123\",\"token\":\"demo-token-123\"}"
    }
  }

  assert {
    condition = (
      resource.aws_lambda_function.sorting_lambda_function[0].function_name == "dev-demo_sdc_aws_sorting_lambda_function" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["SWXSOC_MISSION"] == "demo" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["COMMS_PLATFORM"] == "mattermost" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["MATTERMOST_CHANNEL_ID"] == "demo-channel-123" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["MATTERMOST_TOKEN"] == "demo-token-123" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["MATTERMOST_URL"] == "https://mm.sciencecloud.nasa.gov:443"
    )
    error_message = "A demo Lambda selects the demo mission and posts to the demo Mattermost channel from the dev-demo secret."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_log_group.sorting[0].retention_in_days == 14 &&
      resource.aws_cloudwatch_log_group.sorting[0].tags["Mission"] == "demo"
    )
    error_message = "Demo Lambda log groups keep the shorter 14-day retention."
  }
}
