// Resources for Sorting Lambda function, triggers and the necessary IAM permissions


///////////////////////////////////////
// S3 Sorting Lambda Function
///////////////////////////////////////

// Creates the Sorting Lambda function
resource "aws_lambda_function" "sorting_lambda_function" {
  function_name = "${local.environment_short_name}${var.sorting_function_private_ecr_name}_function"
  memory_size   = 2048
  timeout       = 600

  environment {
    variables = {
      LAMBDA_ENVIRONMENT     = upper(local.environment_full_name)
      SDC_AWS_SLACK_TOKEN    = var.slack_token
      SDC_AWS_SLACK_CHANNEL  = var.slack_channel
      SWXSOC_MISSION         = var.mission_name
      SWXSOC_INCOMING_BUCKET = var.incoming_bucket_name
    }
  }

  image_uri    = "${aws_ecr_repository.sorting_function_private_ecr.repository_url}:${var.sf_image_tag}"
  package_type = "Image"

  ephemeral_storage {
    size = 512
  }

  tracing_config {
    mode = "PassThrough"
  }

  role = aws_iam_role.sorting_lambda_exec.arn


  tags = local.standard_tags

  lifecycle {

    ignore_changes = [
      environment["SDC_AWS_SLACK_TOKEN"],   // Ignore changes to this variable
      environment["SDC_AWS_SLACK_CHANNEL"], // Ignore changes to this variable
    ]
  }
}


///////////////////////////////////////
// S3 Sorting Lambda Function Triggers
///////////////////////////////////////

// Create a CloudWatch event rule to trigger the Lambda function every 12 hours
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "${aws_lambda_function.sorting_lambda_function.function_name}-rule"
  description         = "CloudWatch event trigger for the AWS Sorting Lambda, runs every hour"
  schedule_expression = "cron(0 0/12 * * ? *)"
}

// Attach the Lambda function as a target of the CloudWatch event rule
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "${local.environment_full_name}${upper(var.mission_name)}LambdaTarget"
  arn       = aws_lambda_function.sorting_lambda_function.arn
}

// Create S3 bucket notification to trigger the Lambda function when a file is uploaded
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.sdc_buckets["${var.incoming_bucket_name}"].id
  lambda_function {
    lambda_function_arn = aws_lambda_function.sorting_lambda_function.arn
    events              = ["s3:ObjectCreated:*"]
  }

  // Here, you may want to add a dependency on the necessary IAM permissions
  depends_on = [aws_lambda_permission.sf_allow_cloudwatch, aws_lambda_permission.sf_allow_incoming_bucket]
}

// Allow the Lambda function to be invoked by CloudWatch
resource "aws_lambda_permission" "sf_allow_cloudwatch" {
  statement_id  = "SF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sorting_lambda_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}

// Allow the Lambda function to be invoked by S3
resource "aws_lambda_permission" "sf_allow_incoming_bucket" {
  statement_id  = "SF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sorting_lambda_function.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.sdc_buckets["${var.incoming_bucket_name}"].arn
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
