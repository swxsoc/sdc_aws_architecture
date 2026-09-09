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

# The generate_cloc_report_and_upload and import_UDL_REACH_to_s3 schedules were
# created in the console after the executor was first managed here. Adopt the
# rules, their targets, and their invoke permissions under the live identifiers.
locals {
  console_created_triggers = {
    for trigger in var.lambda_triggers : trigger.name => trigger
    if trigger.target_id != null && trigger.statement_id != null
  }
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? local.console_created_triggers : {}
  to       = aws_cloudwatch_event_rule.lambda_rules[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? local.console_created_triggers : {}
  to       = aws_cloudwatch_event_target.lambda_targets[each.key]
  id       = "${each.key}/${each.value.target_id}"
}

import {
  for_each = var.adopt_existing_base_runtime_resources ? local.console_created_triggers : {}
  to       = aws_lambda_permission.lambda_permissions[each.key]
  id       = "aws_sdc_executor_lambda_function/${each.value.statement_id}"
}
