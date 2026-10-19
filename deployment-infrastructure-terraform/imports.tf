# The projects and selected webhooks predate Terraform. These declarative
# imports adopt them into the dedicated deployment state without recreation.
# Projects in local.new_codebuild_projects (the base architecture project and
# the GDCTB projects and triggers) are created, not imported.
locals {
  adopted_pipeline_projects = { for name, project in local.codebuild_projects : name => project if !contains(local.new_codebuild_projects, name) }
  adopted_support_projects  = { for name, project in local.support_projects : name => project if !contains(local.new_codebuild_projects, name) }
}

import {
  for_each = var.adopt_existing_codebuild_projects ? local.adopted_pipeline_projects : {}
  to       = aws_codebuild_project.pipeline[each.key]
  id       = each.key
}

import {
  for_each = var.adopt_existing_codebuild_projects ? local.adopted_support_projects : {}
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

# Every project's live service role is adopted by name; the one role for the
# new base architecture project is created.
import {
  for_each = var.adopt_existing_codebuild_projects ? toset(distinct(values(local.existing_service_roles))) : toset([])
  to       = aws_iam_role.codebuild[each.key]
  id       = each.key
}
