mock_provider "aws" {}

run "plan_base" {
  command = plan

  variables {
    deployment_region                     = "us-east-1"
    soc_name                              = "swxsoc"
    timestream_database_name              = "swxsoc_sdc_aws_logs"
    timestream_measures_table_name        = "swxsoc_measures_table"
    executor_function_private_ecr_name    = "swxsoc_sdc_aws_executor_lambda"
    alert_function_private_ecr_name       = "swxsoc_sdc_aws_alert_lambda"
    ef_image_tag                          = "test-immutable-sha"
    alert_image_tag                       = "test-alert-immutable-sha"
    grafana_secret_name                   = ""
    udl_secret_name                       = ""
    alert_gcn_secret_name                 = ""
    adopt_existing_base_runtime_resources = false
    s3_access_bucket_names                = ["dev-swxsoc-pipeline-incoming", "swxsoc-pipeline-incoming"]
  }

  override_data {
    target = data.aws_vpc.default
    values = {
      id = "vpc-123456"
    }
  }

  assert {
    condition     = resource.aws_ecr_repository.executor_function_private_ecr.name == "swxsoc_sdc_aws_executor_lambda"
    error_message = "Executor ECR repo name should match the provided variable."
  }

  assert {
    condition = (
      resource.aws_ecr_repository.alert_function_private_ecr.name == "swxsoc_sdc_aws_alert_lambda" &&
      resource.aws_ecr_repository.alert_function_private_ecr.tags["Mission"] == "swxsoc" &&
      resource.aws_ecr_repository.alert_function_private_ecr.tags["Service"] == "alert" &&
      resource.aws_ecr_repository.alert_function_private_ecr.tags["Environment"] == "Production"
    )
    error_message = "Alert ECR should have a predictable name and complete mission/service/environment tags."
  }

  assert {
    condition = (
      resource.aws_ecr_repository.executor_function_private_ecr.tags["Mission"] == "swxsoc" &&
      resource.aws_ecr_repository.executor_function_private_ecr.tags["Service"] == "executor" &&
      resource.aws_ecr_repository.executor_function_private_ecr.tags["Environment"] == "Production" &&
      resource.aws_ecr_repository.executor_function_private_ecr.tags["ManagedBy"] == "terraform" &&
      resource.aws_ecr_repository.executor_function_private_ecr.tags["Project"] == "swxsoc"
    )
    error_message = "Executor ECR should include the complete common and component tags."
  }

  assert {
    condition = (
      resource.aws_lambda_function.aws_sdc_alert_lambda_function.function_name == "aws_sdc_alert_lambda_function" &&
      resource.aws_lambda_function.aws_sdc_alert_lambda_function.tags["Service"] == "alert" &&
      resource.aws_lambda_function.aws_sdc_alert_lambda_function.environment[0].variables["LAMBDA_ENVIRONMENT"] == "PRODUCTION"
    )
    error_message = "Alert Lambda should preserve its production identity and carry alert service tags."
  }

  assert {
    condition = (
      resource.aws_lambda_permission.alert_eventbridge.statement_id == "lambda-8e809099-7565-4fcb-a416-b694da153a2a" &&
      resource.aws_cloudwatch_event_target.alert.target_id == "jc7f7xt2upcwol5ogc67" &&
      resource.aws_cloudwatch_event_rule.alert.schedule_expression == "rate(5 minutes)"
    )
    error_message = "Alert schedule wiring must keep the live identifiers so adoption never replaces the permission or target."
  }

  assert {
    condition = (
      resource.aws_cloudwatch_log_group.executor.retention_in_days == 90 &&
      resource.aws_cloudwatch_log_group.alert.retention_in_days == 90 &&
      resource.aws_cloudwatch_log_group.alert.tags["Service"] == "alert"
    )
    error_message = "Base Lambda logs should be explicitly retained and tagged by service."
  }

  assert {
    condition = (
      resource.aws_lambda_function.aws_sdc_executor_lambda_function.tags["Mission"] == "swxsoc" &&
      resource.aws_lambda_function.aws_sdc_executor_lambda_function.tags["Service"] == "executor" &&
      resource.aws_lambda_function.aws_sdc_executor_lambda_function.tags["Environment"] == "Production" &&
      resource.aws_lambda_function.aws_sdc_executor_lambda_function.tags["ManagedBy"] == "terraform"
    )
    error_message = "Executor Lambda should include the complete common and component tags."
  }

  assert {
    condition     = jsondecode(resource.aws_ecr_lifecycle_policy.executor_function_private_ecr.policy).rules[0].selection.countNumber == 15
    error_message = "Executor ECR lifecycle policy should retain the newest 15 images."
  }

  assert {
    condition     = resource.aws_security_group.lambda_sg.vpc_id == "vpc-123456"
    error_message = "Lambda SG should use the default VPC id."
  }

  assert {
    condition     = resource.aws_secretsmanager_secret.grafana_secret.name == "swxsoc/prod/swxsoc/executor/grafana"
    error_message = "Base secrets should use the environment/mission/service path convention."
  }

  assert {
    condition = (
      resource.aws_secretsmanager_secret.grafana_secret.tags["Service"] == "executor" &&
      resource.aws_secretsmanager_secret.grafana_secret.tags["Environment"] == "Production" &&
      resource.aws_secretsmanager_secret.grafana_secret.tags["ManagedBy"] == "terraform" &&
      resource.aws_secretsmanager_secret.grafana_secret.recovery_window_in_days == 30
    )
    error_message = "Base secrets should have complete tags and a recoverable deletion window."
  }

  assert {
    condition     = resource.aws_iam_role_policy_attachment.ef_s3_access_policy_attachment[0].role == "swxsoc_executor_lambda_exec_role"
    error_message = "Executor role should receive the configured S3 access policy."
  }
}
