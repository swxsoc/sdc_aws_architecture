from aws_cdk import Stack, aws_s3, aws_ecr, Tags, RemovalPolicy, Duration, aws_dynamodb
from constructs import Construct
from . import vars
import logging
import os
from datetime import datetime


class SDCAWSPipelineArchitectureStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        #  Create S3 Log DynamoDB Table
        sdc_aws_pipeline_architecture_dynamodb_table = aws_dynamodb.Table(
            scope=self,
            id="aws_sdc_pipeline_architecture_dynamodb_table",
            table_name="aws_sdc_s3_log_dynamodb_table",
            partition_key=aws_dynamodb.Attribute(
                name="id", type=aws_dynamodb.AttributeType.STRING
            ),
            removal_policy=RemovalPolicy.DESTROY,
        )

        # Apply Standard Tags to DynamoDB Table
        self._apply_standard_tags(sdc_aws_pipeline_architecture_dynamodb_table)

        # Initiate Server Access Logs Bucket
        s3_server_access_bucket = aws_s3.Bucket(
            self,
            f"aws_sdc_{vars.S3_SERVER_ACCESS_LOGS_BUCKET_NAME}_bucket",
            bucket_name=vars.S3_SERVER_ACCESS_LOGS_BUCKET_NAME,
            removal_policy=RemovalPolicy.RETAIN,
            auto_delete_objects=False,
        )

        # Iterate through the S3 Buckets List and Create the Buckets
        for bucket in vars.BUCKET_LIST:

            # Initiate Bucket
            s3_bucket = aws_s3.Bucket(
                self,
                f"aws_sdc_{bucket}_bucket",
                bucket_name=bucket,
                removal_policy=RemovalPolicy.RETAIN,
                auto_delete_objects=False,
                server_access_logs_bucket=s3_server_access_bucket,
                server_access_logs_prefix=f"{bucket}/",
            )

            # Apply Standard Tags to the Bucket
            self._apply_standard_tags(s3_bucket)

            # Log Result
            logging.info(f"Created the {bucket} S3 Bucket")

        # Iterate through the Private ECR Repos and initiate
        for ecr_repo in vars.ECR_PRIVATE_REPO_LIST:

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
        for ecr_repo in vars.ECR_PUBLIC_REPO_LIST:

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
