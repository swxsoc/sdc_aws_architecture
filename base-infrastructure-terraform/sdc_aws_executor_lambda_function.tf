// Resources for Executor Lambda function, RDS DB for CDFTracker, triggers and the necessary IAM permissions


///////////////////////////////////////
// S3 Executor Lambda Function
///////////////////////////////////////

resource "aws_lambda_function" "aws_sdc_executor_lambda_function" {
  function_name = "${local.environment_short_name}aws_sdc_executor_lambda_function"
  role          = aws_iam_role.executor_lambda_exec.arn
  memory_size   = 128
  timeout       = 900

  image_uri    = "${aws_ecr_repository.executor_function_private_ecr.repository_url}:${var.ef_image_tag}"
  package_type = "Image"

  environment {
    variables = {
      LAMBDA_ENVIRONMENT    = upper(local.environment_full_name)
      SECRET_ARN         = aws_secretsmanager_secret.grafana_secret.arn
    }
  }
  ephemeral_storage {
    size = 512
  }

  tracing_config {
    mode = "PassThrough"
  }

}



// KMS key used by Secrets Manager
resource "aws_kms_key" "default" {
  description             = "KMS key"
  deletion_window_in_days = 30
  is_enabled              = true
  enable_key_rotation     = true

  tags = local.standard_tags
}

// Create a secret in Secrets Manager
resource "aws_secretsmanager_secret" "grafana_secret" {
  kms_key_id              = aws_kms_key.default.key_id
  name                    = "${local.environment_short_name}grafana-credentials"
  description             = "Grafana Credentials"
  recovery_window_in_days = 0

  tags = local.standard_tags
}




///////////////////////////////////////
// Executor Lambda Triggers
///////////////////////////////////////
///////////////////////////////////////
// Executor Lambda Triggers
///////////////////////////////////////

// Define triggers as a list of maps
variable "lambda_triggers" {
  default = [
    {
      name          = "create_GOES_data_annotations"
      description   = "CloudWatch event trigger for creating GOES data annotations, at noon UTC"
      # Schedule for noon UTC
      schedule_expr = "cron(0 12 * * ? *)"
    },
    {
      name          = "import_GOES_data_to_timestream"
      description   = "CloudWatch event trigger for importing GOES data to Timestream, at noon UTC"
      schedule_expr = "cron(0 12 * * ? *)"

    }
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
  for_each    = { for trigger in var.lambda_triggers : trigger.name => trigger }
  statement_id  = "AllowCloudWatchToInvoke-${each.value.name}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_executor_lambda_function.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_rules[each.key].arn
}

# CloudWatch Event Targets
resource "aws_cloudwatch_event_target" "lambda_targets" {
  for_each = { for trigger in var.lambda_triggers : trigger.name => trigger }
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




