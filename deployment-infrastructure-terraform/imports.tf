# The projects and selected webhooks predate Terraform. These declarative
# imports adopt them into the dedicated deployment state without recreation.
import {
  for_each = var.adopt_existing_codebuild_projects ? local.codebuild_projects : {}
  to       = aws_codebuild_project.pipeline[each.key]
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
