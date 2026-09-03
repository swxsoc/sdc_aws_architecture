data "aws_secretsmanager_secret" "alert_gcn" {
  name = local.alert_gcn_secret_name
}

resource "aws_cloudwatch_log_group" "executor" {
  name              = "/aws/lambda/${local.environment_short_name}aws_sdc_executor_lambda_function"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.standard_tags, {
    "Service" = "executor"
  })
}

resource "aws_cloudwatch_log_group" "alert" {
  name              = "/aws/lambda/${local.environment_short_name}aws_sdc_alert_lambda_function"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.standard_tags, {
    "Service" = "alert"
  })
}

resource "aws_iam_role" "alert_lambda_exec" {
  name = "${local.environment_short_name}swxsoc_alert_lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = merge(local.standard_tags, {
    "Service" = "alert"
  })
}

resource "aws_iam_role_policy" "alert_lambda_exec" {
  name = "${local.environment_short_name}swxsoc-alert-runtime"
  role = aws_iam_role.alert_lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteFunctionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.alert.arn}:*"
      },
      {
        Sid      = "ReadGcnCredentials"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = data.aws_secretsmanager_secret.alert_gcn.arn
      },
    ]
  })
}

resource "aws_lambda_function" "aws_sdc_alert_lambda_function" {
  function_name = "${local.environment_short_name}aws_sdc_alert_lambda_function"
  role          = aws_iam_role.alert_lambda_exec.arn
  memory_size   = 128
  timeout       = 120
  architectures = ["x86_64"]

  image_uri    = "${aws_ecr_repository.alert_function_private_ecr.repository_url}:${var.alert_image_tag}"
  package_type = "Image"

  environment {
    variables = {
      GCN_CLIENT_ID_SECRET_ARN     = data.aws_secretsmanager_secret.alert_gcn.arn
      GCN_CLIENT_SECRET_SECRET_ARN = data.aws_secretsmanager_secret.alert_gcn.arn
      LAMBDA_ENVIRONMENT           = upper(local.environment_full_name)
      SPACEPY                      = "/tmp"
      SUNPY_CONFIGDIR              = "/tmp"
      SUNPY_DOWNLOADDIR            = "/tmp"
    }
  }

  ephemeral_storage {
    size = 512
  }

  tracing_config {
    mode = "PassThrough"
  }

  tags = merge(local.standard_tags, {
    "Service" = "alert"
  })

  lifecycle {
    precondition {
      condition     = trimspace(var.alert_image_tag) != ""
      error_message = "An immutable alert_image_tag is required for the alert Lambda."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.alert,
    aws_iam_role_policy.alert_lambda_exec,
  ]
}

resource "aws_cloudwatch_event_rule" "alert" {
  name                = "get_goesxrs_alert_stream"
  description         = "maps to goes_xrs_alert_stream()"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  tags = merge(local.standard_tags, {
    "Service" = "alert"
  })
}

# statement_id and target_id force replacement. Both default to the live
# console-created identifiers so the adoption plan updates nothing here and the
# five-minute schedule never has zero or two targets during an apply.
resource "aws_lambda_permission" "alert_eventbridge" {
  statement_id  = var.alert_eventbridge_statement_id
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_alert_lambda_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alert.arn

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_event_target" "alert" {
  rule      = aws_cloudwatch_event_rule.alert.name
  target_id = var.alert_eventbridge_target_id
  arn       = aws_lambda_function.aws_sdc_alert_lambda_function.arn

  lifecycle {
    create_before_destroy = true
  }
}
