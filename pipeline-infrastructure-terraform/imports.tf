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

# Instruments that were wired up by hand under the standard names before
# Terraform managed them. Importing hands them to Terraform, which then applies
# the same configuration as every other instrument. The queue is imported only
# where it already exists and is created everywhere else.
locals {
  adopted_instrument_buckets = toset([
    for name in var.adopt_existing_instruments : "${local.mission_bucket_prefix}-${name}"
  ])
}

data "aws_sqs_queues" "adopted_instrument" {
  for_each          = local.adopted_instrument_buckets
  queue_name_prefix = "${local.environment_short_name}${each.key}-sqs-queue"
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
  for_each = {
    for bucket in local.adopted_instrument_buckets : bucket => one([
      for url in data.aws_sqs_queues.adopted_instrument[bucket].queue_urls : url
      if endswith(url, "/${local.environment_short_name}${bucket}-sqs-queue")
    ])
    if length([
      for url in data.aws_sqs_queues.adopted_instrument[bucket].queue_urls : url
      if endswith(url, "/${local.environment_short_name}${bucket}-sqs-queue")
    ]) == 1
  }
  to = aws_sqs_queue.sqs_queue[each.key]
  id = each.value
}
