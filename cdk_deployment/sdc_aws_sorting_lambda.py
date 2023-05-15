import boto3
from aws_cdk import (
    Stack,
    aws_lambda,
    aws_s3_notifications,
    aws_s3,
    aws_iam,
    Duration,
    aws_events,
    aws_events_targets,
)
from constructs import Construct
import logging
import os
from util import apply_standard_tags, is_production


class SDCAWSSortingLambdaStack(Stack):
    def __init__(
        self, scope: Construct, construct_id: str, config: dict, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Get the environment
        self.is_production = is_production(config)

        # Get the S3 buckets
        incoming_bucket, lambda_bucket = self._get_buckets(config)

        function_name = (
            f"{'' if self.is_production else 'dev_'}aws_sdc_sorting_lambda_function"
        )
        # Create the Lambda function scheduled to run every 12 hours
        s3_lambda_code = self.get_latest_zip_file(config["SORTING_LAMBDA_BUCKET_NAME"])
        lambda_schedule = aws_events.Schedule.cron(hour="0,12", minute="0")
        sdc_aws_sorting_function = self._create_sorting_lambda_function(
            function_name,
            lambda_bucket,
            s3_lambda_code,
            config["DEPLOYMENT_ENVIRONMENT"],
        )

        # Add permissions to the Lambda function
        self._add_timestream_permissions(sdc_aws_sorting_function)
        apply_standard_tags(sdc_aws_sorting_function)

        # Create the CloudWatch event rule
        self._create_cloudwatch_event_rule(
            function_name, sdc_aws_sorting_function, lambda_schedule
        )

        for bucket_name in config["BUCKET_LIST"]:
            bucket = aws_s3.Bucket.from_bucket_name(
                self, f"aws_sdc_{bucket_name}", bucket_name
            )
            bucket.grant_read_write(sdc_aws_sorting_function)

        self._add_s3_event_notification(incoming_bucket, sdc_aws_sorting_function)
        logging.info("Function created successfully: %s", sdc_aws_sorting_function)

    def _get_buckets(self, config):
        incoming_bucket_name = config["INCOMING_BUCKET_NAME"]

        incoming_bucket = aws_s3.Bucket.from_bucket_name(
            self, "aws_sdc_incoming_bucket", incoming_bucket_name
        )
        lambda_bucket_name = config["SORTING_LAMBDA_BUCKET_NAME"]
        lambda_bucket = aws_s3.Bucket.from_bucket_name(
            self, lambda_bucket_name, lambda_bucket_name
        )
        return incoming_bucket, lambda_bucket

    def _create_sorting_lambda_function(
        self, function_name, lambda_bucket, s3_lambda_code, environment
    ):
        return aws_lambda.Function(
            scope=self,
            id=function_name,
            handler="lambda_function.handler",
            runtime=aws_lambda.Runtime.PYTHON_3_9,
            memory_size=128,
            function_name=function_name,
            description=(
                "SWSOC Processing Lambda function deployed using AWS CDK Python"
            ),
            environment={"LAMBDA_ENVIRONMENT": environment},
            timeout=Duration.minutes(10),
            code=aws_lambda.S3Code(lambda_bucket, s3_lambda_code),
        )

    def _add_timestream_permissions(self, lambda_function):
        lambda_function.add_to_role_policy(
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

    def _create_cloudwatch_event_rule(
        self, function_name, lambda_function, lambda_schedule
    ):
        event_target = aws_events_targets.LambdaFunction(handler=lambda_function)
        rule_name = f"{function_name}-rule"
        return aws_events.Rule(
            self,
            rule_name,
            description=(
                "CloudWatch event trigger for the AWS Sorting Lambda, runs every hour"
            ),
            enabled=True,
            schedule=lambda_schedule,
            targets=[event_target],
        )

    def _add_s3_event_notification(self, bucket, lambda_function):
        bucket.add_event_notification(
            aws_s3.EventType.OBJECT_CREATED,
            aws_s3_notifications.LambdaDestination(lambda_function),
        )

    def get_latest_zip_file(self, lambda_bucket_name) -> str:
        if os.getenv("ZIP_FILE"):
            return os.getenv("ZIP_FILE")

        s3 = boto3.client("s3")

        try:
            response = s3.list_objects_v2(
                Bucket=lambda_bucket_name, Prefix="", Delimiter="/"
            )
        except Exception:
            return ""

        zip_files = [
            obj for obj in response.get("Contents", []) if obj["Key"].endswith(".zip")
        ]

        if not zip_files:
            return ""

        latest_zip = max(zip_files, key=lambda x: x["LastModified"])

        return latest_zip["Key"]
