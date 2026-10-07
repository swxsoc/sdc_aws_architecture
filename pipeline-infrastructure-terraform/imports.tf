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

# Instruments that were wired up by hand before Terraform managed them. Their
# bucket and SNS topic exist in every environment; the SQS queue exists only in
# the environments listed in sqs_queue_environments and is created elsewhere.
locals {
  adopted_instrument_buckets = {
    for name, cfg in var.adopt_existing_instruments :
    "${local.mission_bucket_prefix}-${name}" => cfg
  }
}

import {
  for_each = local.adopted_instrument_buckets
  to       = aws_s3_bucket.sdc_buckets[each.key]
  id       = "${local.environment_short_name}${each.key}"
}

import {
  for_each = local.adopted_instrument_buckets
  to       = aws_sns_topic.sns_topics[each.key]
  id       = "arn:aws:sns:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.key}-sns-topic"
}

import {
  for_each = { for bucket, cfg in local.adopted_instrument_buckets : bucket => cfg if contains(cfg.sqs_queue_environments, local.environment_slug) }
  to       = aws_sqs_queue.sqs_queue[each.key]
  id       = "https://sqs.${var.deployment_region}.amazonaws.com/${data.aws_caller_identity.current.account_id}/${local.environment_short_name}${each.key}-sqs-queue"
}
