# Existing mission Lambda log groups were created implicitly by Lambda. Adopt
# them per workspace so retention and cost-allocation tags become declarative.
import {
  for_each = var.adopt_existing_lambda_log_groups && local.enable_processing_lambda ? toset(["/aws/lambda/${local.environment_short_name}${var.processing_function_private_ecr_name}_function"]) : toset([])
  to       = aws_cloudwatch_log_group.processing[0]
  id       = each.key
}

import {
  for_each = var.adopt_existing_lambda_log_groups && local.enable_sorting_lambda ? toset(["/aws/lambda/${local.environment_short_name}${var.sorting_function_private_ecr_name}_function"]) : toset([])
  to       = aws_cloudwatch_log_group.sorting[0]
  id       = each.key
}

import {
  for_each = var.adopt_existing_lambda_log_groups && local.enable_artifacts_lambda ? toset(["/aws/lambda/${local.environment_short_name}${var.artifacts_function_private_ecr_name}_function"]) : toset([])
  to       = aws_cloudwatch_log_group.artifacts[0]
  id       = each.key
}

import {
  for_each = var.adopt_existing_lambda_log_groups && local.enable_concating_lambda ? toset(["/aws/lambda/${local.environment_short_name}${var.concating_function_private_ecr_name}_function"]) : toset([])
  to       = aws_cloudwatch_log_group.concating[0]
  id       = each.key
}
