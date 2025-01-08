// Resource for Infrastructure for the SDC Pipeline

///////////////////////////////////////
// VPC for SDC Pipeline
///////////////////////////////////////
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "public_subnet" {
  for_each = toset(data.aws_subnets.public_subnets.ids)
  id       = each.value
}


///////////////////////////////////////
// Timestream Database for storing logs
///////////////////////////////////////

// Timestream Database for storing logs
resource "aws_timestreamwrite_database" "sdc_aws_timestream_db" {
  database_name = "${local.environment_short_name}${var.timestream_database_name}"
  tags          = local.standard_tags
}

// Timestream Table for storing logs
resource "aws_timestreamwrite_table" "sdc_aws_timestream_measures_table" {
  table_name    = "${local.environment_short_name}${var.timestream_measures_table_name}"
  database_name = aws_timestreamwrite_database.sdc_aws_timestream_db.database_name

  retention_properties {
    memory_store_retention_period_in_hours  = 24
    magnetic_store_retention_period_in_days = 360
  }

  depends_on = [aws_timestreamwrite_database.sdc_aws_timestream_db]
  tags       = local.standard_tags
}


///////////////////////////////////////
// ECR Repositories for SDC Pipeline
///////////////////////////////////////

// Private ECR for the executor function
resource "aws_ecr_repository" "executor_function_private_ecr" {
  name                 = "${local.environment_short_name}${var.executor_function_private_ecr_name}"
  image_tag_mutability = "MUTABLE"
  tags                 = local.standard_tags
}



///////////////////////////////////////
// IAM Policies for SDC Pipeline
///////////////////////////////////////

// Timestream Access Policy
resource "aws_iam_policy" "timestream_policy" {
  name        = "${local.environment_full_name}${upper(var.soc_name)}TimestreamAccessPolicy"
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
  name        = "${local.environment_full_name}${upper(var.soc_name)}LogsAccessPolicy"
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


// Define a policy that grants Lambda permission to access the secret
resource "aws_iam_policy" "lambda_secrets_manager_policy" {
  name_prefix = "${local.environment_short_name}_${var.soc_name}_lambda_secrets_manager_policy_"

  // Define the permissions for accessing the secret
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
        ],
        Effect   = "Allow",
        Resource = aws_secretsmanager_secret.grafana_secret.arn,
      },
    ],
  })
}

// Define a policy that grants Lambda permission to access the KMS key
resource "aws_iam_policy" "lambda_kms_policy" {
  name_prefix = "${local.environment_short_name}${var.soc_name}_lambda_kms_policy_"

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

// IAM Policy for Lambda VPC Access
resource "aws_iam_policy" "lambda_vpc_access_policy" {
  name        = "${local.environment_short_name}${var.soc_name}_lambda_vpc_access_policy"
  description = "Custom policy for Lambda VPC access"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ],
        Resource = "*"
      }
    ]
  })
}


////////////////////////////////////////////
// SGs for Lambda Functions for SDC Pipeline
////////////////////////////////////////////

resource "aws_security_group" "lambda_sg" {
  vpc_id = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
