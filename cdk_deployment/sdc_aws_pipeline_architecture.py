from aws_cdk import Stack, aws_s3, aws_ecr, Tags, RemovalPolicy, Duration
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

            # Bucket name based off current deployment environment
            bucket_name = self._get_construct_name(bucket)

            if (
                os.getenv("CDK_ENVIRONMENT") != "PRODUCTION"
                and bucket in vars.PRODUCTION_ONLY_BUCKET_LIST
            ):
                logging.info(f"Skipping Bucket {bucket_name}")
                continue

            # Initiate Bucket
            # If Environment is Development, applies removal policy + auto-delete
            # If Environment is Production, Retains all resources to keep data safe
            s3_bucket = (
                aws_s3.Bucket(
                    self,
                    f"aws_sdc_{bucket}_bucket",
                    bucket_name=bucket_name,
                    removal_policy=RemovalPolicy.RETAIN,
                    auto_delete_objects=False,
                )
                if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION"
                else aws_s3.Bucket(
                    self,
                    f"aws_sdc_{bucket}_bucket",
                    bucket_name=bucket_name,
                    removal_policy=RemovalPolicy.DESTROY,
                    auto_delete_objects=True,
                )
            )

            # Apply Standard Tags to the Bucket
            self._apply_standard_tags(s3_bucket)

            # Log Result
            logging.info(f"Created the {s3_bucket} S3 Bucket")

        # Iterate through the Private ECR Repos and initiate
        for ecr_repo in vars.ECR_PRIVATE_REPO_LIST:

            # Repo name based off current deployment environment
            repository_name = self._get_construct_name(ecr_repo)

            # Initiate Private Repo
            # If Environment is Development, applies removal policy
            # If Environment is Production, Retains all resources to keep data safe
            private_ecr_repo = (
                aws_ecr.Repository(
                    self,
                    f"aws_sdc_{ecr_repo}_private_repo",
                    repository_name=repository_name,
                    removal_policy=RemovalPolicy.RETAIN,
                )
                if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION"
                else aws_ecr.Repository(
                    self,
                    f"aws_sdc_{ecr_repo}_private_repo",
                    repository_name=repository_name,
                    removal_policy=RemovalPolicy.DESTROY,
                )
            )

            # Apply Lifecycle Policy
            self._apply_ecr_lifecycle_policy(private_ecr_repo)

            # Apply Tags
            self._apply_standard_tags(private_ecr_repo)

            # Log Result
            logging.info(f"Created the {private_ecr_repo} Private ECR Repo")

        # Iterate through the Public ECR Repos and initiate
        for ecr_repo in vars.ECR_PUBLIC_REPO_LIST:

            # Repo name based off current deployment environment
            repository_name = self._get_construct_name(ecr_repo)

            # Initiate Public Repos
            # Note: Public ECR Repos don't support removal policies
            public_ecr_repo = aws_ecr.CfnPublicRepository(
                self,
                f"aws_sdc_{ecr_repo}_private_repo",
                repository_name=repository_name,
            )

            # Apply Tags
            self._apply_standard_tags(public_ecr_repo)

            # Log Result
            logging.info(f"Created the {public_ecr_repo} Public ECR Repo")

    def _get_construct_name(self, resource):
        """
        This function returns the proper resource name based off environment
        """

        # Appends 'dev-' prefix if not in Production
        resource_name = (
            resource
            if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION"
            else f"dev-{resource}"
        )

        return resource_name

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
