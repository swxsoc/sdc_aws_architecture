# // Resources for Processing Artifacts Lambda function, RDS DB for CDFTracker, triggers and the necessary IAM permissions


//////////////////////////////////////////
// S3 Processing Artifacts Lambda Function
//////////////////////////////////////////

resource "aws_lambda_function" "aws_sdc_artifacts_lambda_function" {
  function_name = "${local.environment_short_name}${var.artifacts_function_private_ecr_name}_function"
  role          = aws_iam_role.artifacts_lambda_exec.arn
  memory_size   = 2048
  timeout       = 900

  image_uri    = "${aws_ecr_repository.artifacts_function_private_ecr.repository_url}:${var.af_image_tag}"
  package_type = "Image"

  environment {
    variables = {
      LAMBDA_ENVIRONMENT     = upper(local.environment_full_name)
      RDS_SECRET_ARN         = aws_secretsmanager_secret.rds_secret.arn
      RDS_HOST               = aws_db_instance.rds_instance.address
      RDS_PORT               = tostring(aws_db_instance.rds_instance.port)
      RDS_DATABASE           = aws_db_instance.rds_instance.db_name
      SDC_AWS_SLACK_TOKEN    = var.slack_token
      SDC_AWS_SLACK_CHANNEL  = var.slack_channel
      SWXSOC_MISSION         = var.mission_name
      SWXSOC_INCOMING_BUCKET = var.incoming_bucket_name
      SPACEPY                = "/tmp"
      SUNPY_CONFIGDIR        = "/tmp"
      SUNPY_DOWNLOADDIR      = "/tmp"
    }
  }
  ephemeral_storage {
    size = 512
  }

  tracing_config {
    mode = "PassThrough"
  }

  lifecycle {

    ignore_changes = [
      environment["SDC_AWS_SLACK_TOKEN"],   # Ignore changes to this variable
      environment["SDC_AWS_SLACK_CHANNEL"], # Ignore changes to this variable
    ]
  }

  vpc_config {
    subnet_ids = [data.aws_subnet.public_subnet["subnet-0972d4965ef8eb1e8"].id, data.aws_subnet.public_subnet["subnet-0e24325c69b9a1f74"].id]

    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  tags = local.standard_tags


}


///////////////////////////////////////
// Processing Artifacts Lambda Triggers
///////////////////////////////////////

# Create Lambda permissions for each prefix
resource "aws_lambda_permission" "af_allow_instrument_buckets" {
  for_each      = toset(local.instrument_bucket_names) # Convert to a set to ensure unique permissions
  statement_id  = "PF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromS3Bucket-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_artifacts_lambda_function.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.sdc_buckets[each.value].arn
}

# Create Lambda permissions to be invoked by topic
resource "aws_lambda_permission" "af_allow_sns_topic" {
  for_each      = toset(local.instrument_bucket_names) # Convert to a set to ensure unique permissions
  statement_id  = "PF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromSNSTopic-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_artifacts_lambda_function.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.sns_topics[each.key].arn
}

// Invoke Processing Artifacts Lambda from SNS
resource "aws_sns_topic_subscription" "af_sns_topic_subscription" {
  for_each = toset(local.instrument_bucket_names) # Convert to a set to ensure unique permissions

  topic_arn = aws_sns_topic.sns_topics[each.key].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.aws_sdc_artifacts_lambda_function.arn

  depends_on = [aws_lambda_permission.af_allow_sns_topic]
}



///////////////////////////////////////////////
// Processing Artifacts Lambda IAM Permissions
///////////////////////////////////////////////

// Create an IAM role for the Lambda function
resource "aws_iam_role" "artifacts_lambda_exec" {
  name = "${local.environment_short_name}${upper(var.mission_name)}_artifacts_lambda_exec_role"

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

// Attach needed policies to the role
resource "aws_iam_role_policy_attachment" "af_s3_bucket_policy_attachment" {
  role       = aws_iam_role.artifacts_lambda_exec.name
  policy_arn = aws_iam_policy.s3_bucket_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "af_timestream_policy_attachment" {
  role       = aws_iam_role.artifacts_lambda_exec.name
  policy_arn = aws_iam_policy.timestream_policy.arn
}

resource "aws_iam_role_policy_attachment" "af_logs_policy_attachment" {
  role       = aws_iam_role.artifacts_lambda_exec.name
  policy_arn = aws_iam_policy.logs_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "af_secrets_manager_policy_attachment" {
  role       = aws_iam_role.artifacts_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_secrets_manager_policy.arn
}

resource "aws_iam_role_policy_attachment" "af_lambda_kms_policy_attachment" {
  role       = aws_iam_role.artifacts_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_kms_policy.arn
}

resource "aws_iam_role_policy_attachment" "af_vpc_policy_attachment" {
  role       = aws_iam_role.artifacts_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_vpc_access_policy.arn
}
