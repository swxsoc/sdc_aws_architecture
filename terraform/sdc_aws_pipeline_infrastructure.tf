// Resource for Infrastructure for the SDC Pipeline


///////////////////////////////////////
// Timestream Database for storing logs
///////////////////////////////////////

// Timestream Database for storing logs
resource "aws_timestreamwrite_database" "sdc_aws_timestream_db" {
  database_name = "${local.environment_short_name}${var.timestream_database_name}"
  tags          = local.standard_tags
}

// Timestream Table for storing logs
resource "aws_timestreamwrite_table" "sdc_aws_timestream_table" {
  table_name    = "${local.environment_short_name}${var.timestream_s3_logs_table_name}"
  database_name = aws_timestreamwrite_database.sdc_aws_timestream_db.database_name

  retention_properties {
    memory_store_retention_period_in_hours  = 24
    magnetic_store_retention_period_in_days = 30
  }

  depends_on = [aws_timestreamwrite_database.sdc_aws_timestream_db]
  tags       = local.standard_tags
}


///////////////////////////////////////
// S3 Buckets for SDC Pipeline
///////////////////////////////////////

// Creates the access policy for the access logs bucket if this is the production environment
resource "aws_s3_bucket" "access_logs" {
  count  = local.is_production ? 1 : 0
  bucket = var.s3_server_access_logs_bucket_name

  versioning {
    enabled = true
  }

  tags = local.standard_tags
}

// Creates the access policy for the access logs bucket if this is the production environment
resource "aws_s3_bucket_policy" "access_logs_access_policy" {
  count  = local.is_production ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].bucket

  policy = jsonencode({
    Id      = "S3-Access-Logs-Policy"
    Version = "2012-10-17"
    Statement = [
      {
        Action = "s3:PutObject"
        Effect = "Allow"
        Principal = {
          Service = "logging.s3.amazonaws.com"
        }
        Resource = "arn:aws:s3:::${aws_s3_bucket.access_logs[0].bucket}/*"
        Sid      = "S3PolicyStmt-DO-NOT-MODIFY-1663700656545"
      }
    ]
  })
}

// Creates all the buckets for the pipeline
resource "aws_s3_bucket" "sdc_buckets" {
  for_each = {
    for bucket in local.bucket_list : bucket => bucket
  }

  bucket = "${local.environment_short_name}${each.value}"
  versioning {
    enabled = true
  }

  // Enable server access logging if this is the production environment
  dynamic "logging" {
    for_each = local.environment_short_name == "prod" ? [1] : []
    content {
      target_bucket = aws_s3_bucket.access_logs[0].id
      target_prefix = "${each.value}/"
    }
  }

  tags = local.standard_tags
}


////////////////////////////////////////////
// SNS Topics for SDC Pipeline
////////////////////////////////////////////

// Creates topics for each instrument
resource "aws_sns_topic" "sns_topics" {
  for_each = toset(local.instrument_bucket_names)
  name     = "${local.environment_short_name}${each.value}-sns-topic"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sns:Publish"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::${local.environment_short_name}${each.value}"
          }
        }
        Resource = "arn:aws:sns:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sns-topic"
        Sid      = "SNSPublishAccess-${local.environment_short_name}${each.value}"
      }
    ]
  })
  tags = local.standard_tags
}


////////////////////////////////////////////
// SQS Queues for SDC Pipeline
////////////////////////////////////////////

// Creates queues for each instrument
resource "aws_sqs_queue" "sqs_queue" {
  for_each = toset(local.instrument_bucket_names)

  name = "${local.environment_short_name}${each.value}-sqs-queue"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sqs:SendMessage",
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "arn:aws:sns:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sns-topic"
          }
        },
        Effect = "Allow",
        Principal = {
          Service = "sns.amazonaws.com"
        },
        Resource = "arn:aws:sqs:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sqs-queue"
      },
      {
        Action = ["sqs:ReceiveMessage", "sqs:SendMessage"],
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "arn:aws:sns:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sns-topic"
          }
        },
        Effect = "Allow",
        Principal = {
          AWS = "*"
        },
        Resource = "arn:aws:sqs:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sqs-queue"
      },
      {
        Action = ["sqs:ReceiveMessage", "sqs:SendMessage"],
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "arn:aws:s3:::${local.environment_short_name}${each.value}"
          }
        },
        Effect = "Allow",
        Principal = {
          AWS = "*"
        },
        Resource = "arn:aws:sqs:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sqs-queue"
      },
      {
        Action = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:SendMessage"],
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::${local.environment_short_name}${each.value}"
          }
        },
        Effect = "Allow",
        Principal = {
          Service = "s3.amazonaws.com"
        },
        Resource = "arn:aws:sqs:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:${local.environment_short_name}${each.value}-sqs-queue"
      }
    ]
  })
  sqs_managed_sse_enabled = true
  tags                    = local.standard_tags
}


///////////////////////////////////////
// ECR Repositories for SDC Pipeline
///////////////////////////////////////

// Private ECR for the processing function
resource "aws_ecr_repository" "processing_function_private_ecr" {
  name                 = "${local.environment_short_name}${var.processing_function_private_ecr_name}"
  image_tag_mutability = "MUTABLE"
  tags                 = local.standard_tags
}

// Public ECR for the docker base image
resource "aws_ecrpublic_repository" "docker_base_public_ecr" {
  repository_name = "${local.environment_short_name}${var.docker_base_public_ecr_name}"
  tags            = local.standard_tags
}


///////////////////////////////////////
// IAM Policies for SDC Pipeline
///////////////////////////////////////

// Timestream Access Policy
resource "aws_iam_policy" "timestream_policy" {
  name        = "${local.environment_full_name}TimestreamAccessPolicy"
  description = "Provides access to Timestream"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "timestream:WriteRecords",
          "timestream:DescribeEndpoints",
          "timestream:DescribeDatabase",
          "timestream:DescribeTable"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

// Logs Access Policy
resource "aws_iam_policy" "logs_access_policy" {
  name        = "${local.environment_full_name}LogsAccessPolicy"
  description = "Provides access to CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}


// S3 Bucket Access Policy
resource "aws_iam_policy" "s3_bucket_access_policy" {
  name        = "${local.environment_full_name}S3BucketAccessPolicy"
  description = "Provides access to specific S3 buckets"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:Abort*",
          "s3:DeleteObject*",
          "s3:GetBucket*",
          "s3:GetObject*",
          "s3:List*",
          "s3:PutObject",
          "s3:PutObjectLegalHold",
          "s3:PutObjectRetention",
          "s3:PutObjectTagging",
          "s3:PutObjectVersionTagging"
        ],
        Resource = concat(
          [for b in local.bucket_list : "arn:aws:s3:::${local.environment_short_name}${b}"],
          [for b in local.bucket_list : "arn:aws:s3:::${local.environment_short_name}${b}/*"]
        ),
        Effect = "Allow"
      }
    ]
  })
}

// Define a policy that grants Lambda permission to access the secret
resource "aws_iam_policy" "lambda_secrets_manager_policy" {
  name_prefix = "${local.environment_short_name}lambda_secrets_manager_policy_"

  // Define the permissions for accessing the secret
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
        ],
        Effect   = "Allow",
        Resource = aws_secretsmanager_secret.rds_secret.arn,
      },
    ],
  })
}

// Define a policy that grants Lambda permission to access the KMS key
resource "aws_iam_policy" "lambda_kms_policy" {
  name_prefix = "${local.environment_short_name}lambda_kms_policy_"

  // Define the permissions for accessing the KMS key
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "kms:Decrypt", // Permission to decrypt the secret
        ],
        Effect   = "Allow",
        Resource = aws_kms_key.default.arn // Replace with your KMS key ARN
      },
    ],
  })
}