"""
This contains variables used throughout the SDC Pipeline
"""
# Region that the stack will be deployed to
DEPLOYMENT_REGION = "us-east-1"

# S3 Bucket Names
INCOMING_BUCKET_NAME = "swsoc-incoming"
UNSORTED_BUCKET_NAME = "swsoc-unsorted"
SPANI_BUCKET_NAME = "hermes-spani"
NEMISIS_BUCKET_NAME = "hermes-nemisis"
EEA_BUCKET_NAME = "hermes-eea"
MERIT_BUCKET_NAME = "hermes-merit"
SORTING_LAMBDA_BUCKET_NAME = "swsoc-sorting-lambda"

# S3 Server Access Logs Bucket
S3_SERVER_ACCESS_LOGS_BUCKET_NAME = "swsoc-s3-server-access-logs"
# List of Buckets to be Created
BUCKET_LIST = [
    INCOMING_BUCKET_NAME,
    SPANI_BUCKET_NAME,
    NEMISIS_BUCKET_NAME,
    EEA_BUCKET_NAME,
    MERIT_BUCKET_NAME,
    SORTING_LAMBDA_BUCKET_NAME,
    UNSORTED_BUCKET_NAME,
]

# List of Instrument Bucket Names
INSTRUMENT_BUCKET_LIST = [
    SPANI_BUCKET_NAME,
    NEMISIS_BUCKET_NAME,
    EEA_BUCKET_NAME,
    MERIT_BUCKET_NAME,
]

# ECR Repository Names
PROCESSING_LAMBDA_ECR_NAME = "sdc_aws_processing_lambda"
SWSOC_DOCKER_BASE_ECR_NAME = "swsoc-docker-lambda-base"

# Public ECR Repo List (This is deployed to all regions)
ECR_PUBLIC_REPO_LIST = [SWSOC_DOCKER_BASE_ECR_NAME]

# Private ECR Repo List (This is only deployed to selected region)
ECR_PRIVATE_REPO_LIST = [PROCESSING_LAMBDA_ECR_NAME]

# S3 Bucket DynamoDB Table ARN
S3_BUCKET_DYNAMODB_TABLE_ARN = (
    "arn:aws:dynamodb:us-east-1:351967858401:table/" "aws_sdc_s3_log_dynamodb_table"
)
