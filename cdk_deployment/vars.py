"""
This contains variables used throughout the SDC Pipeline
"""

# S3 Bucket Names
INCOMING_BUCKET_NAME = "swsoc-incoming"
SPANI_BUCKET_NAME = "hermes-spani"
NEMISIS_BUCKET_NAME = "hermes-nemisis"
EEA_BUCKET_NAME = "hermes-eea"
MERIT_BUCKET_NAME = "hermes-merit"
SORTING_LAMBDA_BUCKET_NAME = "swsoc-sorting-lambda"

# List of Buckets to be Created
BUCKET_LIST = [
    INCOMING_BUCKET_NAME,
    SPANI_BUCKET_NAME,
    NEMISIS_BUCKET_NAME,
    EEA_BUCKET_NAME,
    MERIT_BUCKET_NAME,
    SORTING_LAMBDA_BUCKET_NAME,
]

# ECR Repository Names
PROCESSING_LAMBDA_ECR_NAME = "sdc_aws_processing_lambda"
SWSOC_DOCKER_BASE_ECR_NAME = "swsoc-docker-lambda-base"

# Public ECR Repo List (This is deployed to all regions)
ECR_PUBLIC_REPO_LIST = [SWSOC_DOCKER_BASE_ECR_NAME]

# Private ECR Repo List (This is only deployed to selected region)
ECR_PRIVATE_REPO_LIST = [PROCESSING_LAMBDA_ECR_NAME]
