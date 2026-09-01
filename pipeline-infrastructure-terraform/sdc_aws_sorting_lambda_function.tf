// Resources for Sorting Lambda function, triggers and the necessary IAM permissions


///////////////////////////////////////
// S3 Sorting Lambda Function
///////////////////////////////////////

locals {
  sorting_image_uri     = var.sorting_image_uri_override != "" ? var.sorting_image_uri_override : "${aws_ecr_repository.sorting_function_private_ecr.repository_url}:${var.sf_image_tag}"
  enable_sorting_lambda = var.enable_sorting_lambda
}

data "aws_secretsmanager_secret" "mattermost" {
  count = var.enable_mattermost ? 1 : 0
  name  = local.mattermost_secret_name

  lifecycle {
    postcondition {
      condition = (
        lookup(self.tags, "Mission", "") == var.mission_name &&
        lookup(self.tags, "Service", "") == "communications" &&
        lookup(self.tags, "Environment", "") == local.environment_full_name &&
        lookup(self.tags, "ManagedBy", "") == "external"
      )
      error_message = "The Mattermost secret must have the expected Mission, Service=communications, Environment, and ManagedBy=external tags."
    }
  }
}

data "aws_secretsmanager_secret_version" "mattermost" {
  count     = var.enable_mattermost ? 1 : 0
  secret_id = data.aws_secretsmanager_secret.mattermost[0].id

  lifecycle {
    postcondition {
      condition = (
        try(length(trimspace(jsondecode(self.secret_string).token)) > 0, false) &&
        try(length(trimspace(jsondecode(self.secret_string).channel_id)) > 0, false)
      )
      error_message = "The Mattermost secret JSON must contain non-empty string keys named token and channel_id."
    }
  }
}

locals {
  mattermost_credentials = var.enable_mattermost ? jsondecode(data.aws_secretsmanager_secret_version.mattermost[0].secret_string) : {}
  mattermost_environment = var.enable_mattermost ? {
    COMMS_PLATFORM        = "mattermost"
    MATTERMOST_CHANNEL_ID = local.mattermost_credentials.channel_id
    MATTERMOST_TOKEN      = local.mattermost_credentials.token
    MATTERMOST_URL        = var.mattermost_url
  } : {}
}

// Creates the Sorting Lambda function
resource "aws_lambda_function" "sorting_lambda_function" {
  count         = local.enable_sorting_lambda ? 1 : 0
  function_name = "${local.environment_short_name}${var.sorting_function_private_ecr_name}_function"
  memory_size   = 2048
  timeout       = 600

  environment {
    variables = merge({
      LAMBDA_ENVIRONMENT     = upper(local.environment_full_name)
      SDC_AWS_SLACK_TOKEN    = var.slack_token
      SDC_AWS_SLACK_CHANNEL  = var.slack_channel
      SWXSOC_MISSION         = var.mission_name
      SWXSOC_INCOMING_BUCKET = var.incoming_bucket_name
      SPACEPY                = "/tmp"
      SUNPY_CONFIGDIR        = "/tmp"
      SUNPY_DOWNLOADDIR      = "/tmp"
    }, local.mattermost_environment)
  }

  image_uri    = local.sorting_image_uri
  package_type = "Image"

  ephemeral_storage {
    size = 2048
  }

  tracing_config {
    mode = "PassThrough"
  }

  role = aws_iam_role.sorting_lambda_exec.arn


  tags = merge(local.standard_tags, {
    "Service" = "sorting"
  })

  lifecycle {
    ignore_changes = [
      environment["SDC_AWS_SLACK_TOKEN"],   // Ignore changes to this variable
      environment["SDC_AWS_SLACK_CHANNEL"], // Ignore changes to this variable
    ]

    precondition {
      condition = (
        trimspace(var.sorting_image_uri_override) != "" ||
        trimspace(var.sf_image_tag) != ""
      )
      error_message = "An immutable sf_image_tag or sorting_image_uri_override is required for the sorting Lambda."
    }
  }
}


///////////////////////////////////////
// S3 Sorting Lambda Function Triggers
///////////////////////////////////////

// Create a CloudWatch event rule to trigger the Lambda function every 12 hours
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  count               = local.enable_sorting_lambda ? 1 : 0
  name                = "${aws_lambda_function.sorting_lambda_function[0].function_name}-rule"
  description         = "CloudWatch event trigger for the AWS Sorting Lambda, runs every 12 hours"
  schedule_expression = "cron(0 0/12 * * ? *)"
}

// Attach the Lambda function as a target of the CloudWatch event rule
resource "aws_cloudwatch_event_target" "lambda_target" {
  count     = local.enable_sorting_lambda ? 1 : 0
  rule      = aws_cloudwatch_event_rule.lambda_schedule[0].name
  target_id = "${local.environment_full_name}${upper(var.mission_name)}LambdaTarget"
  arn       = aws_lambda_function.sorting_lambda_function[0].arn
}

// Create S3 bucket notification to trigger the Lambda function when a file is uploaded
resource "aws_s3_bucket_notification" "bucket_notification" {
  count  = local.enable_sorting_lambda ? 1 : 0
  bucket = aws_s3_bucket.sdc_buckets[var.incoming_bucket_name].id
  lambda_function {
    lambda_function_arn = aws_lambda_function.sorting_lambda_function[0].arn
    events              = ["s3:ObjectCreated:*"]
  }

  // Here, you may want to add a dependency on the necessary IAM permissions
  depends_on = [aws_lambda_permission.sf_allow_cloudwatch, aws_lambda_permission.sf_allow_incoming_bucket]
}

// Allow the Lambda function to be invoked by CloudWatch
resource "aws_lambda_permission" "sf_allow_cloudwatch" {
  count         = local.enable_sorting_lambda ? 1 : 0
  statement_id  = "SF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sorting_lambda_function[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule[0].arn
}

// Allow the Lambda function to be invoked by S3
resource "aws_lambda_permission" "sf_allow_incoming_bucket" {
  count         = local.enable_sorting_lambda ? 1 : 0
  statement_id  = "SF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sorting_lambda_function[0].function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.sdc_buckets[var.incoming_bucket_name].arn
}


///////////////////////////////////////
// S3 Sorting Lambda Function IAM Permissions
///////////////////////////////////////

// Creates the needed Execution Role for the Sorting Lambda function
resource "aws_iam_role" "sorting_lambda_exec" {
  name = "${local.environment_short_name}${var.mission_name}_sorting_lambda_exec_role"

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

// Attach policies to the Sorting Lambda Execution Role
resource "aws_iam_role_policy_attachment" "sf_timestream_policy_attachment" {
  role       = aws_iam_role.sorting_lambda_exec.name
  policy_arn = aws_iam_policy.timestream_policy.arn
}

resource "aws_iam_role_policy_attachment" "sf_logs_policy_attachment" {
  role       = aws_iam_role.sorting_lambda_exec.name
  policy_arn = aws_iam_policy.logs_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "sf_s3_bucket_policy_attachment" {
  role       = aws_iam_role.sorting_lambda_exec.name
  policy_arn = aws_iam_policy.s3_bucket_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "sf_vpc_policy_attachment" {
  role       = aws_iam_role.sorting_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_vpc_access_policy.arn
}
