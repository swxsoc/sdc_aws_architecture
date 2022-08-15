from aws_cdk import Stack, aws_lambda, aws_s3_notifications, aws_s3
from constructs import Construct
import logging
from . import vars


class SDCAWSSortingLambdaStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Name of Incoming Bucket that will trigger the lambda
        bucket_name = vars.INCOMING_BUCKET_NAME

        # Get the incoming bucket from S3
        incoming_bucket = aws_s3.Bucket.from_bucket_name(
            self, "aws_sdc_incoming_bucket", bucket_name
        )

        # Get the incoming bucket from S3
        lambda_bucket = aws_s3.Bucket.from_bucket_name(
            self, "aws_sdc_lambda_bucket", vars.SORTING_LAMBDA_BUCKET_NAME
        )

        # Create Sorting Lambda Function from Zip
        sdc_aws_sorting_function = aws_lambda.Function(
            scope=self,
            id="aws_sdc_sorting_function",
            handler="lambda_function.handler",
            runtime=aws_lambda.Runtime.PYTHON_3_9,
            memory_size=128,
            function_name="aws_sdc_sorting_lambda_function",
            description=(
                "SWSOC Processing Lambda function deployed using AWS CDK Python"
            ),
            environment={"LAMBDA_ENVIRONMENT": "PRODUCTION"},
            code=aws_lambda.S3Code(
                lambda_bucket, "dev_sorting_function_1660565506.zip"
            ),
        )

        # Grant Access to Buckets
        for bucket in vars.BUCKET_LIST:
            # Get the incoming bucket from S3
            lambda_bucket = aws_s3.Bucket.from_bucket_name(
                self, f"aws_sdc_{bucket}", bucket
            )
            lambda_bucket.grant_read_write(sdc_aws_sorting_function)

        # Add Trigger to the Bucket to call Lambda
        incoming_bucket.add_event_notification(
            aws_s3.EventType.OBJECT_CREATED,
            aws_s3_notifications.LambdaDestination(sdc_aws_sorting_function),
        )

        logging.info("Function created successfully: %s", sdc_aws_sorting_function)
