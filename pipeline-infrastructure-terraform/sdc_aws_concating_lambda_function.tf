// Resources for Concating Lambda function, RDS DB for CDFTracker, triggers and the necessary IAM permissions


///////////////////////////////////////
// S3 Concating Lambda Function
///////////////////////////////////////


resource "aws_lambda_function" "aws_sdc_concating_lambda_function" {
  count = var.needs_concating ? 1 : 0

  function_name = "${local.environment_short_name}${var.concating_function_private_ecr_name}_function"
  role          = aws_iam_role.concating_lambda_exec[0].arn
  memory_size   = 8192
  timeout       = 900

  image_uri    = "${aws_ecr_repository.concating_function_private_ecr[0].repository_url}:${var.cf_image_tag}"
  package_type = "Image"


  environment {
    variables = {
      LAMBDA_ENVIRONMENT     = upper(local.environment_full_name)
      SPACEPY                = "/tmp"
      SUNPY_CONFIGDIR        = "/tmp"
      SUNPY_DOWNLOADDIR      = "/tmp"
      ASTROPY_CACHE_DIR      = "/tmp/astropy_cache"
      MPLCONFIGDIR           = "/tmp/matplotlib"
      RDS_SECRET_ARN         = aws_secretsmanager_secret.rds_secret.arn
      RDS_HOST               = aws_db_instance.rds_instance.address
      RDS_PORT               = tostring(aws_db_instance.rds_instance.port)
      RDS_DATABASE           = aws_db_instance.rds_instance.db_name
      SWXSOC_MISSION         = var.mission_name
      SWXSOC_INCOMING_BUCKET = var.incoming_bucket_name
      GRAFANA_API_KEY        = sensitive(local.grafana["grafana_api_key"])
    }
  }
  ephemeral_storage {
    size = 2048
  }

  tracing_config {
    mode = "PassThrough"
  }


  vpc_config {
    subnet_ids = [data.aws_subnet.public_subnet["subnet-0972d4965ef8eb1e8"].id, data.aws_subnet.public_subnet["subnet-0e24325c69b9a1f74"].id]

    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  tags = local.standard_tags
}




///////////////////////////////////////
// Concating Lambda Triggers
///////////////////////////////////////

resource "aws_cloudwatch_event_rule" "concating_lambda_daily_1am" {
  count               = var.needs_concating ? 1 : 0
  name                = "${local.environment_short_name}${var.mission_name}_concating_lambda_daily_1am"
  description         = "Triggers the concating Lambda at 1am UTC every day"
  schedule_expression = "cron(0 1 * * ? *)"
}

resource "aws_cloudwatch_event_target" "concating_lambda_target" {
  count     = var.needs_concating ? 1 : 0
  rule      = aws_cloudwatch_event_rule.concating_lambda_daily_1am[0].name
  target_id = "concatingLambda"
  arn       = aws_lambda_function.aws_sdc_concating_lambda_function[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge_to_invoke_concating" {
  count         = var.needs_concating ? 1 : 0
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_concating_lambda_function[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.concating_lambda_daily_1am[0].arn
}


///////////////////////////////////////
// Concating Lambda IAM Permissions
///////////////////////////////////////

// Create an IAM role for the Lambda function
resource "aws_iam_role" "concating_lambda_exec" {
  count = var.needs_concating ? 1 : 0
  name  = "${local.environment_short_name}${var.mission_name}_concating_lambda_exec_role"

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

resource "aws_iam_policy" "cf_lambda_self_invoke_policy" {
  count = var.needs_concating ? 1 : 0

  name = "${local.environment_short_name}${var.mission_name}_self"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "lambda:InvokeFunction",
        Effect   = "Allow",
        Resource = aws_lambda_function.aws_sdc_concating_lambda_function[0].arn
      }
    ]
  })
}


// Attach needed policies to the role
resource "aws_iam_role_policy_attachment" "cf_s3_bucket_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.s3_bucket_access_policy.arn
}


resource "aws_iam_role_policy_attachment" "cf_logs_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.logs_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "cf_secrets_manager_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.lambda_secrets_manager_policy.arn
}

resource "aws_iam_role_policy_attachment" "cf_timestream_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.timestream_policy.arn
}


resource "aws_iam_role_policy_attachment" "cf_lambda_kms_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.lambda_kms_policy.arn
}

resource "aws_iam_role_policy_attachment" "cf_vpc_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.lambda_vpc_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "cf_self_invoke_policy_attachment" {
  count = var.needs_concating ? 1 : 0

  role       = aws_iam_role.concating_lambda_exec[0].name
  policy_arn = aws_iam_policy.cf_lambda_self_invoke_policy[0].arn
}
