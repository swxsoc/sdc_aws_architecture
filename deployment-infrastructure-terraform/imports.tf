# The projects and selected webhooks predate Terraform. These declarative
# imports adopt them into the dedicated deployment state without recreation.
# build_swxsoc_sdc_aws_base_architecture is new and is created, not imported.
import {
  for_each = var.adopt_existing_codebuild_projects ? { for name, project in local.codebuild_projects : name => project if !contains(local.new_codebuild_projects, name) } : {}
  to       = aws_codebuild_project.pipeline[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects ? local.support_projects : {}
  to       = aws_codebuild_project.support[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects ? local.existing_image_webhooks : toset([])
  to       = aws_codebuild_webhook.image[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects ? local.existing_architecture_webhooks : toset([])
  to       = aws_codebuild_webhook.architecture[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects ? setintersection(local.existing_support_webhooks, toset(keys(local.dependency_trigger_projects))) : toset([])
  to       = aws_codebuild_webhook.dependency_trigger[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects && contains(local.existing_support_webhooks, "padre-reprocessing-requests") ? toset(["padre-reprocessing-requests"]) : toset([])
  to       = aws_codebuild_webhook.reprocessing
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects ? local.existing_codebuild_log_groups : toset([])
  to       = aws_cloudwatch_log_group.codebuild[each.key]
  id       = "/aws/codebuild/${each.key}"
}
