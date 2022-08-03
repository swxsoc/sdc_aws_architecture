from aws_cdk import Stack, aws_s3, aws_ecr, Tags
from constructs import Construct
from . import vars
import logging
import os
from datetime import datetime


class SDCAWSPipelineArchitectureStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Iterate through the S3 Buckets List and Create the Buckets
        for bucket in vars.BUCKET_LIST:

            # Initiate Bucket
            s3_bucket = aws_s3.Bucket(
                self, f"aws_sdc_{bucket}_bucket", bucket_name=bucket
            )

            # Apply Tags
            self._apply_standard_tags(s3_bucket)

            # Log Result
            logging.info(f"Created the {s3_bucket} S3 Bucket")

        # Iterate through the Private ECR Repos and initiate
        for ecr_repo in vars.ECR_PRIVATE_REPO_LIST:

            # Initiate Repo
            private_ecr_repo = aws_ecr.Repository(
                self, f"aws_sdc_{ecr_repo}_private_repo", repository_name=ecr_repo
            )

            # Apply Tags
            self._apply_standard_tags(private_ecr_repo)

            # Log Result
            logging.info(f"Created the {private_ecr_repo} Private ECR Repo")

        # Iterate through the Public ECR Repos and initiate
        for ecr_repo in vars.ECR_PUBLIC_REPO_LIST:

            # Initiate Repo
            public_ecr_repo = aws_ecr.CfnPublicRepository(
                self, f"aws_sdc_{ecr_repo}_public_repo", repository_name=ecr_repo
            )

            # Apply Tags
            Tags.of(public_ecr_repo).add(
                "Purpose", "SWSOC Pipeline", apply_to_launched_instances=True
            )

            # Log Result
            logging.info(f"Created the {public_ecr_repo} Public ECR Repo")

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

        # Standard Environment Tag
        Tags.of(construct).add("Environment", "Production")

        # Git Version Tag If It Exists
        if os.getenv("GIT_TAG"):
            Tags.of(construct).add("Version", os.getenv("GIT_TAG"))
