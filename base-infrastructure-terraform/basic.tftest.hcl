mock_provider "aws" {}

run "plan_base" {
  command = plan

  variables {
    deployment_region                  = "us-east-1"
    soc_name                           = "swxsoc"
    timestream_database_name           = "swxsoc_sdc_aws_logs"
    timestream_measures_table_name     = "swxsoc_measures_table"
    executor_function_private_ecr_name = "swxsoc_sdc_aws_executor_lambda"
    s3_access_bucket_names             = ["dev-swxsoc-pipeline-incoming", "swxsoc-pipeline-incoming"]
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
      resource.aws_ecr_repository.executor_function_private_ecr.tags["Mission"] == "swxsoc" &&
      resource.aws_ecr_repository.executor_function_private_ecr.tags["Service"] == "sdc-aws-base-infrastructure"
    )
    error_message = "Base resources should include the required Mission and Service tags."
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
    condition     = resource.aws_secretsmanager_secret.grafana_secret.tags["Service"] == "executor"
    error_message = "Base secrets should be tagged with their consuming service."
  }

  assert {
    condition     = resource.aws_iam_role_policy_attachment.ef_s3_access_policy_attachment[0].role == "swxsoc_executor_lambda_exec_role"
    error_message = "Executor role should receive the configured S3 access policy."
  }
}
