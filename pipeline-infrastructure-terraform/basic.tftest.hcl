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

# demo is the lightweight test mission: craft only (the stock mission), no
# concating, no Grafana, Mattermost as its only external secret, short log
# retention, and every Lambda disabled until its image exists. These runs
# re-state the values; demo.tftest.hcl validates demo.tfvars itself.
run "plan_demo_bootstrap" {
  command = plan

  variables {
    deployment_region                     = "us-east-1"
    mission_name                          = "demo"
    resource_purpose                      = "SWxSOC demo mission pipeline test bed"
    instrument_names                      = ["craft"]
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
    condition     = local.instrument_names == tolist(["craft"])
    error_message = "The demo mission is craft only: the stock mission shape."
  }

  assert {
    condition = (
      resource.aws_s3_bucket.sdc_buckets["demo-swsoc-incoming"].bucket == "dev-demo-swsoc-incoming" &&
      resource.aws_s3_bucket.sdc_buckets["demo-craft"].bucket == "dev-demo-craft" &&
      length(resource.aws_s3_bucket.sdc_buckets) == 2 &&
      resource.aws_s3_bucket.sdc_buckets["demo-craft"].tags["Mission"] == "demo" &&
      resource.aws_s3_bucket.sdc_buckets["demo-craft"].tags["Purpose"] == "SWxSOC demo mission pipeline test bed"
    )
    error_message = "The demo mission should create exactly the incoming and craft buckets with demo tags."
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
    instrument_names                      = ["craft"]
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

run "plan_rds_operator_prefix_list" {
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
    rds_operator_prefix_list_name        = "swxsoc-rds-operator-access"
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

  override_data {
    target = data.aws_ec2_managed_prefix_list.rds_operators[0]
    values = {
      id   = "pl-0123456789abcdef0"
      name = "swxsoc-rds-operator-access"
    }
  }

  assert {
    condition = length([
      for rule in resource.aws_security_group.rds_sg.ingress : rule
      if contains(coalesce(rule.prefix_list_ids, []), "pl-0123456789abcdef0") && rule.from_port == 5432 && rule.to_port == 5432
    ]) == 1
    error_message = "RDS should allow Postgres from the operator prefix list when one is named."
  }

  assert {
    condition = length([
      for rule in resource.aws_security_group.rds_sg.ingress : rule
      if length(coalesce(rule.cidr_blocks, [])) > 0
    ]) == 0
    error_message = "No operator CIDR blocks should be written into the RDS security group from this repository."
  }
}

# Pipeline health defaults: every workspace gets the alert topic, the
# per-stage alarms and log filters, the reconciliation Lambda, the composite
# alarm and the dashboard, and nothing is subscribed until a mission opts in.
run "plan_pipeline_health_defaults" {
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
      resource.aws_sns_topic.pipeline_alerts[0].name == "dev-swxsoc-pipeline-pipeline-alerts" &&
      resource.aws_sns_topic.pipeline_alerts[0].tags["Service"] == "pipeline-health" &&
      length(resource.aws_sns_topic_subscription.pipeline_alert_emails) == 0 &&
      length(resource.aws_lambda_function.pipeline_alert_notifier) == 0
    )
    error_message = "The alert topic should exist by default with nothing subscribed to it."
  }

  assert {
    condition = (
      sort(keys(resource.aws_cloudwatch_metric_alarm.lambda_errors)) == sort(["sorting", "processing", "artifacts"]) &&
      sort(keys(resource.aws_cloudwatch_metric_alarm.lambda_throttles)) == sort(["sorting", "processing", "artifacts"]) &&
      sort(keys(resource.aws_cloudwatch_metric_alarm.lambda_duration)) == sort(["sorting", "processing", "artifacts"]) &&
      sort(keys(resource.aws_cloudwatch_metric_alarm.lambda_log_errors)) == sort(["sorting", "processing", "artifacts"]) &&
      !contains(keys(resource.aws_cloudwatch_metric_alarm.lambda_errors), "concating")
    )
    error_message = "Each enabled Lambda stage, and only those, should get errors, throttles, duration and log-errors alarms."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_metric_alarm.lambda_errors["processing"].alarm_name == "dev-swxsoc-pipeline-pipeline-processing-errors" &&
      resource.aws_cloudwatch_metric_alarm.lambda_errors["processing"].dimensions["FunctionName"] == "dev-swxsoc_pipeline_sdc_aws_processing_lambda_function" &&
      resource.aws_cloudwatch_metric_alarm.lambda_errors["processing"].treat_missing_data == "notBreaching" &&
      length(resource.aws_cloudwatch_metric_alarm.lambda_errors["processing"].alarm_actions) == 1 &&
      length(resource.aws_cloudwatch_metric_alarm.lambda_errors["processing"].ok_actions) == 1
    )
    error_message = "Lambda alarms should watch the workspace's function, stay quiet on missing data, and notify the alert topic on both transitions."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_metric_alarm.lambda_duration["processing"].threshold == 810000 &&
      resource.aws_cloudwatch_metric_alarm.lambda_duration["sorting"].threshold == 540000 &&
      resource.aws_cloudwatch_metric_alarm.lambda_duration["processing"].statistic == "Maximum"
    )
    error_message = "Duration alarms should fire at 90% of each function's own timeout, in milliseconds."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["processing"].log_group_name == "/aws/lambda/dev-swxsoc_pipeline_sdc_aws_processing_lambda_function" &&
      strcontains(resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["processing"].pattern, "Error Processing Event") &&
      strcontains(resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["sorting"].pattern, "Issue parsing file") &&
      startswith(resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["artifacts"].pattern, "\"'status': 'ERROR'\" -") &&
      !strcontains(resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["artifacts"].pattern, "?") &&
      alltrue([for term in ["comms client", "Slack", "slack", "Mattermost", "mattermost", "message_ts"] : strcontains(resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["artifacts"].pattern, " -\"${term}\"")]) &&
      resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["processing"].metric_transformation[0].namespace == "SWxSOC/Pipeline/dev-swxsoc-pipeline" &&
      resource.aws_cloudwatch_log_metric_filter.lambda_log_errors["processing"].metric_transformation[0].name == "ProcessingLogErrors" &&
      resource.aws_cloudwatch_metric_alarm.lambda_log_errors["processing"].metric_name == "ProcessingLogErrors" &&
      resource.aws_cloudwatch_metric_alarm.lambda_log_errors["processing"].namespace == "SWxSOC/Pipeline/dev-swxsoc-pipeline"
    )
    error_message = "Log metric filters should count each stage's failure lines (for artifacts every ERROR entry except comms errors) into the workspace namespace that the alarm reads."
  }

  assert {
    condition = (
      keys(resource.aws_cloudwatch_metric_alarm.topic_delivery_failures) == ["swxsoc-pipeline-reach"] &&
      resource.aws_cloudwatch_metric_alarm.topic_delivery_failures["swxsoc-pipeline-reach"].alarm_name == "dev-swxsoc-pipeline-pipeline-reach-topic-delivery-failures" &&
      resource.aws_cloudwatch_metric_alarm.topic_delivery_failures["swxsoc-pipeline-reach"].dimensions["TopicName"] == "dev-swxsoc-pipeline-reach-sns-topic" &&
      resource.aws_cloudwatch_metric_alarm.queue_age["swxsoc-pipeline-reach"].dimensions["QueueName"] == "dev-swxsoc-pipeline-reach-sqs-queue" &&
      resource.aws_cloudwatch_metric_alarm.queue_age["swxsoc-pipeline-reach"].threshold == 21600
    )
    error_message = "Every instrument should get a topic delivery-failure alarm and a queue-age alarm named after the instrument."
  }

  assert {
    condition = (
      resource.aws_lambda_function.pipeline_reconciliation[0].function_name == "dev-swxsoc_pipeline_pipeline_reconciliation" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].runtime == "python3.12" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].handler == "reconcile.handler" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["MISSION"] == "swxsoc_pipeline" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["INCOMING_BUCKET"] == "dev-swxsoc-pipeline-incoming" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["INSTRUMENT_BUCKETS"] == "dev-swxsoc-pipeline-reach" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["DATA_LEVELS"] == "raw,l0,l1" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["TIMESTREAM_DATABASE"] == "dev-swxsoc_pipeline_sdc_aws_logs" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["METRIC_NAMESPACE"] == "SWxSOC/Pipeline/dev-swxsoc-pipeline" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["WINDOW_HOURS"] == "24" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["GRACE_MINUTES"] == "60" &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["SKIP_RDS"] == "false" &&
      length(resource.aws_lambda_function.pipeline_reconciliation[0].vpc_config) == 1 &&
      resource.aws_lambda_function.pipeline_reconciliation[0].tags["Service"] == "pipeline-health"
    )
    error_message = "The reconciliation Lambda should be configured from the workspace's own names and join the Lambda VPC so it can reach RDS."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_event_rule.pipeline_reconciliation[0].schedule_expression == "rate(60 minutes)" &&
      resource.aws_cloudwatch_log_group.pipeline_reconciliation[0].name == "/aws/lambda/dev-swxsoc_pipeline_pipeline_reconciliation" &&
      resource.aws_cloudwatch_log_group.pipeline_reconciliation[0].retention_in_days == 90 &&
      resource.aws_cloudwatch_log_group.pipeline_reconciliation[0].tags["Service"] == "pipeline-health" &&
      resource.aws_lambda_permission.pipeline_reconciliation_schedule[0].principal == "events.amazonaws.com"
    )
    error_message = "The reconciliation should run hourly from EventBridge with a retained, tagged log group."
  }

  assert {
    condition = (
      sort(keys(resource.aws_cloudwatch_metric_alarm.reconciliation_counts)) == sort(["unsorted-incoming-objects", "missing-metatracker-rows", "missing-timestream-records", "reconciliation-check-errors"]) &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_counts["missing-metatracker-rows"].metric_name == "MissingMetaTrackerRows" &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_counts["missing-metatracker-rows"].period == 3600 &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_not_running[0].treat_missing_data == "breaching" &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_not_running[0].evaluation_periods == 2 &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_errors[0].dimensions["FunctionName"] == "dev-swxsoc_pipeline_pipeline_reconciliation"
    )
    error_message = "The reconciliation metrics should each have an alarm, and a missing run marker should itself alarm."
  }

  assert {
    condition = (
      length(local.pipeline_alarm_names) == 20 &&
      resource.aws_cloudwatch_composite_alarm.pipeline_unhealthy[0].alarm_name == "dev-swxsoc-pipeline-pipeline-unhealthy" &&
      strcontains(resource.aws_cloudwatch_composite_alarm.pipeline_unhealthy[0].alarm_rule, "ALARM(\"dev-swxsoc-pipeline-pipeline-processing-log-errors\")") &&
      strcontains(resource.aws_cloudwatch_composite_alarm.pipeline_unhealthy[0].alarm_rule, "ALARM(\"dev-swxsoc-pipeline-pipeline-missing-metatracker-rows\")") &&
      length(regexall("ALARM\\(", resource.aws_cloudwatch_composite_alarm.pipeline_unhealthy[0].alarm_rule)) == 20
    )
    error_message = "The composite alarm should OR together every alarm the workspace creates: 3 stages x 4, 1 instrument x 2, 4 reconciliation counts, not-running and reconciliation errors."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_dashboard.pipeline[0].dashboard_name == "dev-swxsoc-pipeline-pipeline" &&
      length(jsondecode(resource.aws_cloudwatch_dashboard.pipeline[0].dashboard_body).widgets) == 12 &&
      length(jsondecode(resource.aws_cloudwatch_dashboard.pipeline[0].dashboard_body).widgets[1].properties.alarms) == 20
    )
    error_message = "The dashboard should show the chain widgets, one pair per Lambda stage, and every alarm's state."
  }
}

# Opting in: email subscriptions and the Mattermost notifier; and without the
# Lambda VPC the database check is skipped rather than attempted.
run "plan_pipeline_health_opt_in" {
  command = plan

  variables {
    deployment_region                        = "us-east-1"
    mission_name                             = "swxsoc_pipeline"
    instrument_names                         = ["reach"]
    include_craft_instrument                 = false
    valid_data_levels                        = ["raw", "l0", "l1"]
    timestream_database_name                 = "swxsoc_pipeline_sdc_aws_logs"
    timestream_s3_logs_table_name            = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                     = "swxsoc-pipeline-incoming"
    s3_server_access_logs_bucket_name        = "swxsoc-pipeline-s3-server-access-logs"
    sorting_function_private_ecr_name        = "swxsoc_pipeline_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name      = "swxsoc_pipeline_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name     = "swxsoc_pipeline_sdc_aws_processing_lambda"
    concating_function_private_ecr_name      = "swxsoc_pipeline_sdc_aws_concating_lambda"
    docker_base_public_ecr_name              = "swxsoc-pipeline-docker-lambda-base"
    needs_concating                          = false
    enable_grafana_secret                    = false
    comms_platform                           = "mattermost"
    enable_mattermost                        = true
    enable_processing_lambda                 = false
    enable_sorting_lambda                    = true
    enable_artifacts_lambda                  = false
    enable_concating_lambda                  = false
    adopt_existing_lambda_log_groups         = false
    sf_image_tag                             = "test-immutable-sha"
    enable_lambda_vpc                        = false
    pipeline_alert_emails                    = ["soc@example.org", "oncall@example.org"]
    enable_pipeline_alerts_mattermost        = true
    pipeline_reconciliation_interval_minutes = 30
    pipeline_reconciliation_window_hours     = 48
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
      length(resource.aws_sns_topic_subscription.pipeline_alert_emails) == 2 &&
      resource.aws_sns_topic_subscription.pipeline_alert_emails["soc@example.org"].protocol == "email" &&
      resource.aws_sns_topic_subscription.pipeline_alert_notifier[0].protocol == "lambda"
    )
    error_message = "Opting in should subscribe each email address and the Mattermost notifier to the alert topic."
  }

  assert {
    condition = (
      resource.aws_lambda_function.pipeline_alert_notifier[0].function_name == "dev-swxsoc_pipeline_pipeline_alert_notifier" &&
      resource.aws_lambda_function.pipeline_alert_notifier[0].handler == "notifier.handler" &&
      resource.aws_lambda_function.pipeline_alert_notifier[0].environment[0].variables["MATTERMOST_CHANNEL_ID"] == "channel-123" &&
      resource.aws_lambda_function.pipeline_alert_notifier[0].environment[0].variables["MATTERMOST_TOKEN"] == "token-123" &&
      resource.aws_lambda_function.pipeline_alert_notifier[0].environment[0].variables["MATTERMOST_URL"] == "https://mm.sciencecloud.nasa.gov:443" &&
      length(resource.aws_lambda_function.pipeline_alert_notifier[0].vpc_config) == 0 &&
      resource.aws_lambda_permission.pipeline_alert_notifier_sns[0].principal == "sns.amazonaws.com"
    )
    error_message = "The notifier should reuse the mission's Mattermost secret, stay outside the VPC, and be invocable by the alert topic."
  }

  assert {
    condition = (
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["SKIP_RDS"] == "true" &&
      length(resource.aws_lambda_function.pipeline_reconciliation[0].vpc_config) == 0 &&
      resource.aws_lambda_function.pipeline_reconciliation[0].environment[0].variables["WINDOW_HOURS"] == "48" &&
      resource.aws_cloudwatch_event_rule.pipeline_reconciliation[0].schedule_expression == "rate(30 minutes)" &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_counts["unsorted-incoming-objects"].period == 1800 &&
      resource.aws_cloudwatch_metric_alarm.reconciliation_not_running[0].period == 1800
    )
    error_message = "Without the Lambda VPC the reconciliation must skip the RDS check, and the interval should drive the schedule and alarm periods."
  }

  assert {
    condition = (
      keys(local.monitored_lambdas) == ["sorting"] &&
      length(local.pipeline_alarm_names) == 12
    )
    error_message = "With only the sorting Lambda enabled the alarm set should shrink to that stage plus the instrument and reconciliation alarms."
  }
}

# Both switches off: no health resource at all, and nothing else changes.
run "plan_pipeline_health_disabled" {
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
    enable_artifacts_lambda              = false
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    sf_image_tag                         = "test-immutable-sha"
    enable_pipeline_alarms               = false
    enable_pipeline_reconciliation       = false
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
      length(resource.aws_sns_topic.pipeline_alerts) == 0 &&
      length(resource.aws_cloudwatch_metric_alarm.lambda_errors) == 0 &&
      length(resource.aws_cloudwatch_log_metric_filter.lambda_log_errors) == 0 &&
      length(resource.aws_cloudwatch_metric_alarm.topic_delivery_failures) == 0 &&
      length(resource.aws_cloudwatch_metric_alarm.queue_age) == 0 &&
      length(resource.aws_cloudwatch_composite_alarm.pipeline_unhealthy) == 0 &&
      length(resource.aws_cloudwatch_dashboard.pipeline) == 0 &&
      length(resource.aws_lambda_function.pipeline_reconciliation) == 0 &&
      length(resource.aws_cloudwatch_event_rule.pipeline_reconciliation) == 0 &&
      length(resource.aws_cloudwatch_metric_alarm.reconciliation_counts) == 0 &&
      length(local.pipeline_alarm_names) == 0
    )
    error_message = "Turning both health switches off must leave no health resource behind."
  }
}

run "reject_mattermost_alerts_without_mattermost" {
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
    comms_platform                       = "slack"
    enable_mattermost                    = false
    enable_processing_lambda             = false
    enable_sorting_lambda                = true
    enable_artifacts_lambda              = false
    enable_concating_lambda              = false
    adopt_existing_lambda_log_groups     = false
    sf_image_tag                         = "test-immutable-sha"
    enable_pipeline_alerts_mattermost    = true
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

  expect_failures = [
    var.enable_pipeline_alerts_mattermost,
  ]
}

# A window shorter than the run interval plus the grace period leaves objects
# that are never judged: too fresh at one run, outside the window at the next.
# Here a daily run meets the default 24 hour window and 60 minute grace.
run "reject_reconciliation_window_shorter_than_interval_plus_grace" {
  command = plan

  variables {
    deployment_region                        = "us-east-1"
    mission_name                             = "swxsoc_pipeline"
    instrument_names                         = ["reach"]
    include_craft_instrument                 = false
    valid_data_levels                        = ["raw", "l0", "l1"]
    timestream_database_name                 = "swxsoc_pipeline_sdc_aws_logs"
    timestream_s3_logs_table_name            = "swxsoc_pipeline_sdc_aws_s3_bucket_log_table"
    incoming_bucket_name                     = "swxsoc-pipeline-incoming"
    s3_server_access_logs_bucket_name        = "swxsoc-pipeline-s3-server-access-logs"
    sorting_function_private_ecr_name        = "swxsoc_pipeline_sdc_aws_sorting_lambda"
    artifacts_function_private_ecr_name      = "swxsoc_pipeline_sdc_aws_artifacts_lambda"
    processing_function_private_ecr_name     = "swxsoc_pipeline_sdc_aws_processing_lambda"
    concating_function_private_ecr_name      = "swxsoc_pipeline_sdc_aws_concating_lambda"
    docker_base_public_ecr_name              = "swxsoc-pipeline-docker-lambda-base"
    needs_concating                          = false
    enable_grafana_secret                    = false
    comms_platform                           = "slack"
    enable_mattermost                        = false
    enable_processing_lambda                 = false
    enable_sorting_lambda                    = true
    enable_artifacts_lambda                  = false
    enable_concating_lambda                  = false
    adopt_existing_lambda_log_groups         = false
    sf_image_tag                             = "test-immutable-sha"
    pipeline_reconciliation_interval_minutes = 1440
    pipeline_reconciliation_window_hours     = 24
    pipeline_reconciliation_grace_minutes    = 60
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

  expect_failures = [
    var.pipeline_reconciliation_interval_minutes,
  ]
}
