// Resources for Processing Lambda function, RDS DB for CDFTracker, triggers and the necessary IAM permissions


///////////////////////////////////////
// S3 Processing Lambda Function
///////////////////////////////////////

resource "aws_lambda_function" "aws_sdc_processing_lambda_function" {
  function_name = "${local.environment_short_name}${var.processing_function_private_ecr_name}_function"
  role          = aws_iam_role.processing_lambda_exec.arn
  memory_size   = 128
  timeout       = 900

  image_uri    = "${aws_ecr_repository.processing_function_private_ecr.repository_url}:${var.pf_image_tag}"
  package_type = "Image"

  environment {
    variables = {
      LAMBDA_ENVIRONMENT = upper(local.environment_full_name)
      SPACEPY            = "/tmp"
      SUNPY_CONFIGDIR    = "/tmp"
      SUNPY_DOWNLOADDIR  = "/tmp"
      SWXSOC_MISSION   = var.mission_name
      SWXSOC_INCOMING_BUCKET = var.incoming_bucket_name
    }
  }
  ephemeral_storage {
    size = 512
  }

  tracing_config {
    mode = "PassThrough"
  }

  tags = local.standard_tags
}


///////////////////////////////////////
// RDS DB for CDFTracker
///////////////////////////////////////

// Generate a random password
resource "random_password" "password" {
  length  = 32
  special = false

  # Ignore changes to the special variable
  lifecycle {
    ignore_changes = [length, special]
  }
}

// KMS key used by Secrets Manager for RDS
resource "aws_kms_key" "default" {
  description             = "KMS key for RDS"
  deletion_window_in_days = 30
  is_enabled              = true
  enable_key_rotation     = true

  tags = local.standard_tags
}

// Create a secret in Secrets Manager
resource "aws_secretsmanager_secret" "rds_secret" {
  kms_key_id              = aws_kms_key.default.key_id
  name                    = "${local.environment_short_name}${var.mission_name}-rds-credentials"
  description             = "RDS Credentials"
  recovery_window_in_days = 0

  tags = local.standard_tags
}

// Store the secret in Secrets Manager
resource "aws_secretsmanager_secret_version" "secret" {
  secret_id = aws_secretsmanager_secret.rds_secret.id
  secret_string = jsonencode({
    username = "cdftracker_user"
    password = random_password.password.result
    host     = aws_db_instance.rds_instance.address
    port     = aws_db_instance.rds_instance.port
    dbname   = aws_db_instance.rds_instance.db_name
    engine   = "postgres"
  })
}

// Create the RDS instance
resource "aws_db_instance" "rds_instance" {
  allocated_storage = 30
  storage_type      = "gp2"
  engine            = "postgres"
  engine_version    = "14.10"
  instance_class    = "db.t3.micro"
  db_name           = local.is_production ? "${var.mission_name}_db" : "dev_${var.mission_name}_db"

  username = "cdftracker_user"
  password = random_password.password.result

  parameter_group_name = "default.postgres14"
  skip_final_snapshot  = true

  multi_az                   = false
  publicly_accessible        = true
  storage_encrypted          = false
  auto_minor_version_upgrade = true
  deletion_protection        = true

  tags = local.standard_tags
}


///////////////////////////////////////
// Processing Lambda Triggers
///////////////////////////////////////

# Create Lambda permissions for each prefix
resource "aws_lambda_permission" "pf_allow_instrument_buckets" {
  for_each      = toset(local.instrument_bucket_names) # Convert to a set to ensure unique permissions
  statement_id  = "PF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromS3Bucket-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_processing_lambda_function.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.sdc_buckets[each.value].arn
}

# Create Lambda permissions to be invoked by topic
resource "aws_lambda_permission" "pf_allow_sns_topic" {
  for_each      = toset(local.instrument_bucket_names) # Convert to a set to ensure unique permissions
  statement_id  = "PF${local.environment_full_name}${upper(var.mission_name)}AllowExecutionFromSNSTopic-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aws_sdc_processing_lambda_function.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.sns_topics[each.key].arn
}

// Create S3 bucket notification to trigger the Lambda function when a file is processed
resource "aws_s3_bucket_notification" "pf_bucket_notification" {
  count = length(local.instrument_bucket_names)

  bucket = aws_s3_bucket.sdc_buckets[local.instrument_bucket_names[count.index]].id

  dynamic "topic" {
    for_each = local.data_levels
    content {
      topic_arn     = aws_sns_topic.sns_topics[local.instrument_bucket_names[count.index]].arn
      events        = ["s3:ObjectCreated:Put", "s3:ObjectCreated:Copy"]
      filter_prefix = local.data_levels[topic.key]
    }
  }

  # Add a dependency on the necessary IAM permissions
  depends_on = [aws_lambda_permission.pf_allow_instrument_buckets]
}

// Invoke Processing Lambda from SNS
resource "aws_sns_topic_subscription" "pf_sns_topic_subscription" {
  for_each = toset(local.instrument_bucket_names) # Convert to a set to ensure unique permissions

  topic_arn = aws_sns_topic.sns_topics[each.key].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.aws_sdc_processing_lambda_function.arn

  depends_on = [aws_lambda_permission.pf_allow_sns_topic]
}


///////////////////////////////////////
// Processing Lambda IAM Permissions
///////////////////////////////////////

// Create an IAM role for the Lambda function
resource "aws_iam_role" "processing_lambda_exec" {
  name = "${local.environment_short_name}${var.mission_name}_processing_lambda_exec_role"

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
resource "aws_iam_role_policy_attachment" "pf_s3_bucket_policy_attachment" {
  role       = aws_iam_role.processing_lambda_exec.name
  policy_arn = aws_iam_policy.s3_bucket_access_policy.arn
}


resource "aws_iam_role_policy_attachment" "pf_logs_policy_attachment" {
  role       = aws_iam_role.processing_lambda_exec.name
  policy_arn = aws_iam_policy.logs_access_policy.arn
}


resource "aws_iam_role_policy_attachment" "pf_lambda_kms_policy_attachment" {
  role       = aws_iam_role.processing_lambda_exec.name
  policy_arn = aws_iam_policy.lambda_kms_policy.arn
}




