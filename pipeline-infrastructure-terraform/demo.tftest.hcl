# Validates the checked-in demo.tfvars itself, rather than a copy of its
# values, in the two states the dev-demo workspace passes through: the
# bootstrap apply with every Lambda off, and the steady state with all three
# Lambdas on. The variables come from the file on the command line, so this
# file must be run alone (a -var-file applies to every test file):
#
#   TF_WORKSPACE=dev-demo terraform test -filter=demo.tftest.hcl -var-file=demo.tfvars
#
# make tf-test-pipeline and CI run it that way. The pattern works for any
# mission's tfvars: only the override_data blocks below are demo-specific.
mock_provider "aws" {
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

run "demo_tfvars_bootstrap" {
  command = plan

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
    condition     = terraform.workspace == "dev-demo" && var.mission_name == "demo"
    error_message = "Run this file under TF_WORKSPACE=dev-demo with -var-file=demo.tfvars."
  }

  assert {
    condition = (
      length(resource.aws_lambda_function.aws_sdc_processing_lambda_function) == 0 &&
      length(resource.aws_lambda_function.sorting_lambda_function) == 0 &&
      length(resource.aws_lambda_function.aws_sdc_artifacts_lambda_function) == 0 &&
      length(resource.aws_lambda_function.aws_sdc_concating_lambda_function) == 0
    )
    error_message = "demo.tfvars as checked in must plan the bootstrap state: every enable_*_lambda flag false, so no Lambda and no image tag needed."
  }

  assert {
    condition     = sort(keys(resource.aws_s3_bucket.sdc_buckets)) == sort(["demo-craft", "demo-swsoc-incoming"])
    error_message = "demo.tfvars must create exactly the incoming and craft buckets: demo is craft only."
  }

  # Names other repositories derive from the mission name, which demo.tfvars
  # must therefore spell exactly this way: the Lambda image buildspecs push to
  # <mission>_sdc_aws_<component>_lambda and pull the base image from
  # <mission>-swsoc-docker-lambda-base; swxsoc's Timestream logger writes to
  # <mission>_sdc_aws_logs / <mission>_sdc_aws_s3_bucket_log_table; and the
  # smoke test in the deployment root uploads to <mission>-swsoc-incoming.
  assert {
    condition = (
      var.processing_function_private_ecr_name == "${var.mission_name}_sdc_aws_processing_lambda" &&
      var.sorting_function_private_ecr_name == "${var.mission_name}_sdc_aws_sorting_lambda" &&
      var.artifacts_function_private_ecr_name == "${var.mission_name}_sdc_aws_artifacts_lambda" &&
      var.docker_base_public_ecr_name == "${var.mission_name}-swsoc-docker-lambda-base" &&
      var.timestream_database_name == "${var.mission_name}_sdc_aws_logs" &&
      var.timestream_s3_logs_table_name == "${var.mission_name}_sdc_aws_s3_bucket_log_table" &&
      var.incoming_bucket_name == "${var.mission_name}-swsoc-incoming"
    )
    error_message = "demo.tfvars must keep the names the Lambda buildspecs, the swxsoc package, and the demo smoke test derive from the mission name."
  }

  assert {
    condition = (
      var.needs_concating == false &&
      var.enable_grafana_secret == false &&
      var.enable_mattermost == true &&
      local.mattermost_secret_name == "swxsoc/dev/demo/communications/mattermost" &&
      length(data.aws_secretsmanager_secret.grafana) == 0
    )
    error_message = "demo stays minimal: no concating, no Grafana, and one external secret, the dev-demo Mattermost secret."
  }
}

# The same tfvars with every Lambda turned on: the state the mission reaches
# after bootstrap. Exercises the full notification fan-out.
run "demo_tfvars_all_lambdas" {
  command = plan

  variables {
    enable_processing_lambda = true
    enable_sorting_lambda    = true
    enable_artifacts_lambda  = true
    pf_image_tag             = "test-immutable-sha"
    sf_image_tag             = "test-immutable-sha"
    af_image_tag             = "test-immutable-sha"
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

  # Incoming bucket -> sorting Lambda
  assert {
    condition = (
      length(resource.aws_s3_bucket_notification.bucket_notification) == 1 &&
      length(resource.aws_s3_bucket_notification.bucket_notification[0].lambda_function) == 1
    )
    error_message = "The incoming bucket must notify the sorting Lambda."
  }

  # Instrument buckets -> one SNS topic per instrument, one notification per
  # data level -> processing and artifacts Lambdas
  assert {
    condition = (
      length(resource.aws_s3_bucket_notification.pf_bucket_notification) == 1 &&
      alltrue([for n in resource.aws_s3_bucket_notification.pf_bucket_notification : length(n.topic) == length(var.valid_data_levels)]) &&
      keys(resource.aws_sns_topic_subscription.pf_sns_topic_subscription) == ["demo-craft"] &&
      keys(resource.aws_sns_topic_subscription.af_sns_topic_subscription) == ["demo-craft"]
    )
    error_message = "The craft bucket, the only instrument bucket, must fan out every data level to the processing and artifacts Lambdas."
  }

  assert {
    condition = (
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["SWXSOC_MISSION"] == "demo" &&
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["SWXSOC_INCOMING_BUCKET"] == "demo-swsoc-incoming" &&
      resource.aws_lambda_function.aws_sdc_processing_lambda_function[0].environment[0].variables["GRAFANA_API_KEY"] == "" &&
      resource.aws_lambda_function.aws_sdc_artifacts_lambda_function[0].environment[0].variables["MATTERMOST_CHANNEL_ID"] == "demo-channel-123" &&
      resource.aws_lambda_function.sorting_lambda_function[0].environment[0].variables["COMMS_PLATFORM"] == "mattermost"
    )
    error_message = "All three demo Lambdas must select the demo mission; artifacts and sorting must post to Mattermost."
  }

  assert {
    condition = alltrue([
      for g in [resource.aws_cloudwatch_log_group.processing[0], resource.aws_cloudwatch_log_group.sorting[0], resource.aws_cloudwatch_log_group.artifacts[0]] :
      g.retention_in_days == var.lambda_log_retention_days && g.tags["Mission"] == "demo"
    ])
    error_message = "Every demo Lambda log group keeps the tfvars retention."
  }
}
