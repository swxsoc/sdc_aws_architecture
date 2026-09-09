resource "aws_cloudwatch_log_group" "processing" {
  count = local.enable_processing_lambda ? 1 : 0

  name              = "/aws/lambda/${local.environment_short_name}${var.processing_function_private_ecr_name}_function"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.standard_tags, {
    "Service" = "processing"
  })
}

resource "aws_cloudwatch_log_group" "sorting" {
  count = local.enable_sorting_lambda ? 1 : 0

  name              = "/aws/lambda/${local.environment_short_name}${var.sorting_function_private_ecr_name}_function"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.standard_tags, {
    "Service" = "sorting"
  })
}

resource "aws_cloudwatch_log_group" "artifacts" {
  count = local.enable_artifacts_lambda ? 1 : 0

  name              = "/aws/lambda/${local.environment_short_name}${var.artifacts_function_private_ecr_name}_function"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.standard_tags, {
    "Service" = "artifacts"
  })
}

resource "aws_cloudwatch_log_group" "concating" {
  count = local.enable_concating_lambda ? 1 : 0

  name              = "/aws/lambda/${local.environment_short_name}${var.concating_function_private_ecr_name}_function"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.standard_tags, {
    "Service" = "concating"
  })
}

