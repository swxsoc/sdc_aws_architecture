// Resources for Executor Lambda function, RDS DB for CDFTracker, triggers and the necessary IAM permissions


///////////////////////////////////////
// S3 Executor Lambda Function
///////////////////////////////////////

resource "aws_lambda_function" "aws_sdc_executor_lambda_function" {
  function_name = "${local.environment_short_name}aws_sdc_executor_lambda_function"
  role          = aws_iam_role.executor_lambda_exec.arn
  memory_size   = var.executor_memory_size
  timeout       = 900

  image_uri    = "${aws_ecr_repository.executor_function_private_ecr.repository_url}:${var.ef_image_tag}"
  package_type = "Image"

  environment {
    variables = {
      GITHUB_ORGS_USERS             = "PADRESat,swxsoc,HERMES-SOC"
      LAMBDA_ENVIRONMENT            = upper(local.environment_full_name)
      REACH_DESTINATION_BUCKET_DEV  = var.reach_destination_bucket_dev
      REACH_DESTINATION_BUCKET_PROD = var.reach_destination_bucket_prod
      REACH_FILE_FORMAT             = "csv"
      REACH_WINDOW_DAYS             = "1"
      REACH_WINDOW_END_DAYS_AGO     = "1"
      S3_BUCKET                     = var.github_report_bucket_name
      # These exact names are the executor image's current runtime contract;
      # the legacy SECRET_ARN name is no longer consumed by the application.
      SECRET_ARN_GRAFANA = aws_secretsmanager_secret.grafana_secret.arn
      SECRET_ARN_UDL     = data.aws_secretsmanager_secret.udl.arn
      SPACEPY            = "/tmp"
      SUNPY_CONFIGDIR    = "/tmp"
      SUNPY_DOWNLOADDIR  = "/tmp"
      # ccsdspy intentionally defines this mixed-case environment variable.
      ccsdspy_CONFIGDIR = "/tmp/config/ccsdspy/"
    }
  }
  ephemeral_storage {
    size = var.executor_ephemeral_storage_size
  }

  tracing_config {
    mode = "PassThrough"
  }

  tags = merge(local.standard_tags, {
    "Service" = "executor"
  })

  lifecycle {
    precondition {
      condition     = trimspace(var.ef_image_tag) != ""
      error_message = "An immutable ef_image_tag is required for the executor Lambda."
    }
  }

  depends_on = [aws_cloudwatch_log_group.executor]
}

data "aws_secretsmanager_secret" "udl" {
  name = local.udl_secret_name
}



// KMS key used by Secrets Manager
resource "aws_kms_key" "default" {
  description             = "KMS key"
  deletion_window_in_days = 30
  is_enabled              = true
  enable_key_rotation     = true

  tags = merge(local.standard_tags, {
    "Service" = "executor"
  })
}

// Create a secret in Secrets Manager
resource "aws_secretsmanager_secret" "grafana_secret" {
  kms_key_id              = aws_kms_key.default.key_id
  name                    = local.grafana_secret_name
  description             = "Grafana Credentials"
  recovery_window_in_days = 30

  tags = merge(local.standard_tags, {
    "Service" = "executor"
  })

  lifecycle {
    create_before_destroy = true
  }
}




///////////////////////////////////////
// Executor Lambda Triggers
///////////////////////////////////////

// Define triggers as a list of maps
variable "lambda_triggers" {
  type = list(object({
    name          = string
    description   = string
    schedule_expr = string
  }))

  default = [
    {
      name        = "create_GOES_data_annotations"
      description = "CloudWatch event trigger for creating GOES data annotations, at noon UTC"
      # Schedule for noon UTC
      schedule_expr = "cron(0 12 * * ? *)"
    },
    {
      name          = "import_GOES_data_to_timestream"
      description   = "CloudWatch event trigger for importing GOES data to Timestream hourly"
      schedule_expr = "rate(1 hour)"

    },
    {
      name          = "generate_cloc_report_and_upload"
      description   = "CloudWatch event trigger to generate CLOC report and upload to S3, every 6 hours"
      schedule_expr = "cron(0 */6 * * ? *)"
    },
    {
      name          = "import_UDL_REACH_to_s3"
      description   = "CloudWatch event trigger for importing the previous complete REACH day"
      schedule_expr = "cron(0 6 * * ? *)"
    },
  ]
}

// Iterate over each trigger and create resources
# CloudWatch Event Rules
resource "aws_cloudwatch_event_rule" "lambda_rules" {
  for_each            = { for trigger in var.lambda_triggers : trigger.name => trigger }
  name                = each.value.name
  description         = each.value.description
  schedule_expression = each.value.schedule_expr
}

# Lambda Permissions
resource "aws_lambda_permission" "lambda_permissions" {
  for_each      = { for trigger in var.lambda_triggers : trigger.name => trigger }
  statement_id  = "AllowCloudWatchToInvoke-${each.value.name}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_executor_lambda_function.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_rules[each.key].arn
}

# CloudWatch Event Targets
resource "aws_cloudwatch_event_target" "lambda_targets" {
  for_each  = { for trigger in var.lambda_triggers : trigger.name => trigger }
  rule      = aws_cloudwatch_event_rule.lambda_rules[each.key].name
  target_id = "aws-sdc-executor-target-${each.value.name}"
  arn       = aws_lambda_function.aws_sdc_executor_lambda_function.arn
}


///////////////////////////////////////
// Executor Lambda IAM Permissions
///////////////////////////////////////

// Create an IAM role for the Lambda function
resource "aws_iam_role" "executor_lambda_exec" {
  name = "swxsoc_executor_lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "ef_timestream_policy_attachment" {
  role       = aws_iam_role.executor_lambda_exec.name
  policy_arn = aws_iam_policy.timestream_policy.arn

}

resource "aws_iam_role_policy_attachment" "ef_logs_policy_attachment" {
  role       = aws_iam_role.executor_lambda_exec.name
  policy_arn = aws_iam_policy.logs_access_policy.arn
}


resource "aws_iam_role_policy_attachment" "ef_lambda_kms_policy_attachment" {
  role       = aws_iam_role.executor_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_kms_policy.arn
}

resource "aws_iam_role_policy_attachment" "ef_lambda_secrets_manager_policy_attachment" {
  role       = aws_iam_role.executor_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_secrets_manager_policy.arn

}

resource "aws_iam_role_policy_attachment" "ef_s3_access_policy_attachment" {
  count = length(local.s3_access_bucket_names) > 0 ? 1 : 0

  role       = aws_iam_role.executor_lambda_exec.name
  policy_arn = aws_iam_policy.s3_access_policy[0].arn
}
