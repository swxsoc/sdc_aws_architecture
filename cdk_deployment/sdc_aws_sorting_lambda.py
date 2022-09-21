from aws_cdk import (
    Stack,
    aws_lambda,
    aws_s3_notifications,
    aws_s3,
    aws_iam,
    Duration,
    aws_events,
    aws_events_targets,
    Tags,
)
from datetime import datetime
from constructs import Construct
import logging
import os
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

        # Lambda Schedule to sort any missed files
        lambda_schedule = aws_events.Schedule.cron(hour="0,12", minute="0")

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
            timeout=Duration.minutes(10),
            code=aws_lambda.S3Code(lambda_bucket, f"{os.getenv('ZIP_NAME')}"),
        )

        # Give Lambda Read/Write Access to all Timestream Tables
        sdc_aws_sorting_function.add_to_role_policy(
            aws_iam.PolicyStatement(
                effect=aws_iam.Effect.ALLOW,
                actions=[
                    "timestream:WriteRecords",
                    "timestream:DescribeEndpoints",
                    "timestream:DescribeDatabase",
                    "timestream:DescribeTable",
                ],
                resources=["*"],
            )
        )

        # Apply Standard Tags to Lambda Function
        self._apply_standard_tags(sdc_aws_sorting_function)

        # Attach schedule to lambda function with target
        event_target = aws_events_targets.LambdaFunction(
            handler=sdc_aws_sorting_function
        )

        # Create Cloudwatch Event Rule to trigger Lambda
        lambda_cw_event = aws_events.Rule(
            self,
            "aws_sdc_lambda_cw_event",
            description="CloudWatch event trigger for the AWS Sorting Lambda,"
            "runs every hour",
            enabled=True,
            schedule=lambda_schedule,
            targets=[event_target],
        )

        # Apply Standard Tags to CW Event
        self._apply_standard_tags(lambda_cw_event)

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

    def _apply_standard_tags(self, construct):
        """
        This function applies the default tags to the different resources created
        """

        # Standard Purpose Tag
        Tags.of(construct).add(
            "Purpose", "SWSOC Pipeline", apply_to_launched_instances=True
        )

        # Standard Last Modified Tag
        Tags.of(construct).add("Last Modified", str(datetime.today()))

        # Environment Name
        environment_name = (
            "Production"
            if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION"
            else "Development"
        )

        # Standard Environment Tag
        Tags.of(construct).add("Environment", environment_name)

        # Git Version Tag If It Exists
        if os.getenv("GIT_TAG"):
            Tags.of(construct).add("Version", os.getenv("GIT_TAG"))
