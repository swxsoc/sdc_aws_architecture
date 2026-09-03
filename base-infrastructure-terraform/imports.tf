# The alert runtime and both base Lambda log groups predate Terraform. These
# imports adopt them without reading or copying the value-bearing GCN secret.
import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["swxsoc_sdc_aws_alert_lambda"]) : toset([])
  to       = aws_ecr_repository.alert_function_private_ecr
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["aws_sdc_alert_lambda_function"]) : toset([])
  to       = aws_lambda_function.aws_sdc_alert_lambda_function
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["get_goesxrs_alert_stream"]) : toset([])
  to       = aws_cloudwatch_event_rule.alert
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["aws_sdc_alert_lambda_function/${var.alert_eventbridge_statement_id}"]) : toset([])
  to       = aws_lambda_permission.alert_eventbridge
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["get_goesxrs_alert_stream/${var.alert_eventbridge_target_id}"]) : toset([])
  to       = aws_cloudwatch_event_target.alert
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["/aws/lambda/aws_sdc_alert_lambda_function"]) : toset([])
  to       = aws_cloudwatch_log_group.alert
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? toset(["/aws/lambda/aws_sdc_executor_lambda_function"]) : toset([])
  to       = aws_cloudwatch_log_group.executor
  id       = each.key
}
