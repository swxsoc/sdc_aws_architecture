from aws_cdk import (
    Stack,
    aws_s3,
    aws_ecr,
    Tags,
    RemovalPolicy,
    Duration,
    aws_timestream,
)
from constructs import Construct
import logging
import os
from datetime import datetime


class SDCAWSPipelineArchitectureStack(Stack):
    def __init__(
        self, scope: Construct, construct_id: str, config: dict, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Create AWS Timestream Database for Logs
        timestream_database = aws_timestream.CfnDatabase(
            self,
            id="timestream_database",
            database_name=config["TIMESTREAM_DATABASE_NAME"],
        )

        # Create AWS Timestream Table for Logs
        timestream_s3_log_table = aws_timestream.CfnTable(
            self,
            id="timestream_table",
            database_name=config["TIMESTREAM_DATABASE_NAME"],
            table_name=config["TIMESTREAM_S3_LOGS_TABLE_NAME"],
            retention_properties={
                "MagneticStoreRetentionPeriodInDays": 30,
                "MemoryStoreRetentionPeriodInHours": 24,
            },
        )

        # Apply Standard Tags
        self._apply_standard_tags(timestream_database)
        self._apply_standard_tags(timestream_s3_log_table)

        # Initiate Server Access Logs Bucket
        s3_server_access_bucket = aws_s3.Bucket(
            self,
            f"aws_sdc_{config['S3_SERVER_ACCESS_LOGS_BUCKET_NAME']}_bucket",
            bucket_name=config["S3_SERVER_ACCESS_LOGS_BUCKET_NAME"],
            removal_policy=RemovalPolicy.RETAIN,
            auto_delete_objects=False,
            versioned=True,
        )

        # Iterate through the S3 Buckets List and Create the Buckets
        for bucket in config["BUCKET_LIST"]:
            if bucket == config["S3_SERVER_ACCESS_LOGS_BUCKET_NAME"]:
                continue

            # Initiate Bucket
            s3_bucket = aws_s3.Bucket(
                self,
                f"aws_sdc_{bucket}_bucket",
                bucket_name=bucket,
                removal_policy=RemovalPolicy.RETAIN,
                auto_delete_objects=False,
                server_access_logs_bucket=s3_server_access_bucket,
                server_access_logs_prefix=f"{bucket}/",
                versioned=True,
            )

            # Apply Standard Tags to the Bucket
            self._apply_standard_tags(s3_bucket)

            # Log Result
            logging.info(f"Created the {bucket} S3 Bucket")

        # Iterate through the Private ECR Repos and initiate
        for ecr_repo in config["ECR_PRIVATE_REPO_LIST"]:

            # Initiate Private Repo
            private_ecr_repo = aws_ecr.Repository(
                self,
                f"aws_sdc_{ecr_repo}_private_repo",
                repository_name=ecr_repo,
                removal_policy=RemovalPolicy.RETAIN,
            )

            # Apply Lifecycle Policy
            self._apply_ecr_lifecycle_policy(private_ecr_repo)

            # Apply Tags
            self._apply_standard_tags(private_ecr_repo)

            # Log Result
            logging.info(f"Created the {ecr_repo} Private ECR Repo")

        # Iterate through the Public ECR Repos and initiate
        for ecr_repo in config["ECR_PUBLIC_REPO_LIST"]:

            # Initiate Public Repos
            # Note: Public ECR Repos don't support removal policies
            public_ecr_repo = aws_ecr.CfnPublicRepository(
                self, f"aws_sdc_{ecr_repo}_private_repo", repository_name=ecr_repo
            )

            # Apply Tags
            self._apply_standard_tags(public_ecr_repo)

            # Log Result
            logging.info(f"Created the {ecr_repo} Public ECR Repo")

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

    def _apply_ecr_lifecycle_policy(self, ecr_repository):
        """
        Apply common lifecycle rules to clean old images from ECR Repositories
        Note: Order does matter when creates Lifecycle Policies. For more info:
        https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html
        """

        # Applies Lifecycle rule to preserve images tagged with a version tag
        # (i.e. v0.0.1, v1, v*)
        ecr_repository.add_lifecycle_rule(
            description="Keeps images prefixed with version tag (e.i. v0.0.1)",
            tag_prefix_list=["v"],
            max_image_count=9999,
        )

        # Applies Lifecycle rule to preserve images tagged with a latest tag
        # (i.e. latest)
        ecr_repository.add_lifecycle_rule(
            description="Keeps images prefixed with latest ",
            tag_prefix_list=["latest"],
            max_image_count=9999,
        )

        # Applies Lifecycle rule to remove images older than 30 days
        # that aren't preserved by the above rules
        ecr_repository.add_lifecycle_rule(max_image_age=Duration.days(30))
