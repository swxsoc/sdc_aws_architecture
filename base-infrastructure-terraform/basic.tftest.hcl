mock_provider "aws" {}

run "plan_base" {
  command = plan

  variables {
    deployment_region             = "us-east-1"
    soc_name                      = "swxsoc"
    timestream_database_name      = "swxsoc_sdc_aws_logs"
    timestream_measures_table_name = "swxsoc_measures_table"
    executor_function_private_ecr_name = "swxsoc_sdc_aws_executor_lambda"
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
    condition     = resource.aws_ecr_repository.executor_function_private_ecr.name == "swxsoc_sdc_aws_executor_lambda"
    error_message = "Executor ECR repo name should match the provided variable."
  }

  assert {
    condition     = resource.aws_security_group.lambda_sg.vpc_id == "vpc-123456"
    error_message = "Lambda SG should use the default VPC id."
  }
}
