from aws_cdk import (
    Stack,
    aws_s3,
    aws_ecr,
    RemovalPolicy,
    Duration,
    aws_timestream,
    aws_s3_notifications,
    aws_sns,
    aws_sqs,
    aws_sns_subscriptions,
    aws_iam,
)
from constructs import Construct
import logging
from util import apply_standard_tags, is_production


class SDCAWSPipelineArchitectureStack(Stack):
    def __init__(
        self, scope: Construct, construct_id: str, config: dict, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        logging.info("Creating AWS Pipeline Architecture Stack...")

        self.is_production = is_production(config)

        # Create AWS Timestream resources
        (
            timestream_database,
            timestream_s3_log_table,
        ) = self._create_timestream_resources(config)

        # # Create S3 resources
        s3_server_access_bucket, s3_buckets = self._create_s3_resources(config)

        # Create Private ECR repositories
        private_ecr_repos = self._create_private_ecr_repos(config)

        # Create Public ECR repositories
        public_ecr_repos = self._create_public_ecr_repos(config)

        logging.info(
            "Finished creating AWS Pipeline Architecture Stack,"
            f"{timestream_database}, {timestream_s3_log_table},"
            f"{s3_server_access_bucket}, {s3_buckets}, {private_ecr_repos},"
            f"{public_ecr_repos}"
        )

    def _create_timestream_resources(self, config):
        database_name = config["TIMESTREAM_DATABASE_NAME"]
        database_id = f"{'' if self.is_production else 'dev_'}timestream_database"
        timestream_database = aws_timestream.CfnDatabase(
            self,
            id=database_id,
            database_name=database_name,
        )

        table_name = config["TIMESTREAM_S3_LOGS_TABLE_NAME"]
        table_id = f"{'' if self.is_production else 'dev_'}timestream_table"
        timestream_s3_log_table = aws_timestream.CfnTable(
            self,
            id=table_id,
            database_name=database_name,
            table_name=table_name,
            retention_properties={
                "MagneticStoreRetentionPeriodInDays": 30,
                "MemoryStoreRetentionPeriodInHours": 24,
            },
        )

        timestream_s3_log_table.add_depends_on(timestream_database)

        apply_standard_tags(timestream_database)
        apply_standard_tags(timestream_s3_log_table)

        return timestream_database, timestream_s3_log_table

    def _create_s3_resources(self, config):
        service_bucket_name = config["S3_SERVER_ACCESS_LOGS_BUCKET_NAME"]

        if self.is_production:
            s3_server_access_bucket = aws_s3.Bucket(
                self,
                f"aws_sdc_{service_bucket_name}_bucket",
                bucket_name=service_bucket_name,
                removal_policy=RemovalPolicy.RETAIN,
                auto_delete_objects=False,
                versioned=True,
            )
        else:
            s3_server_access_bucket = None

        s3_buckets = []
        for bucket in config["BUCKET_LIST"]:
            if bucket == config["S3_SERVER_ACCESS_LOGS_BUCKET_NAME"]:
                continue

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

            if config["MISSION_NAME"] in bucket:
                topic_name = f"{bucket}-sns-topic"
                # Create an SNS topic for the bucket
                sns_topic = aws_sns.Topic(self, topic_name, topic_name=topic_name)

                # Create a bucket notification for the SNS topic
                bucket_notification = aws_s3_notifications.SnsDestination(sns_topic)

                queue_name = f"{bucket}-sqs-queue"

                # Unencrypted queue
                sqs_queue = aws_sqs.Queue(
                    self,
                    queue_name,
                    queue_name=queue_name,
                    encryption=aws_sqs.QueueEncryption.UNENCRYPTED,
                )

                sub = aws_sns_subscriptions.SqsSubscription(
                    sqs_queue, raw_message_delivery=True
                )

                sns_topic.add_subscription(sub)

                # Add a policy statement to the queue
                # to allow the SNS topic to send messages
                sqs_queue.add_to_resource_policy(
                    aws_iam.PolicyStatement(
                        actions=["sqs:SendMessage", "sqs:ReceiveMessage"],
                        effect=aws_iam.Effect.ALLOW,
                        principals=[aws_iam.ArnPrincipal("*")],
                        resources=[sqs_queue.queue_arn],
                        conditions={
                            "ArnEquals": {"aws:SourceArn": sns_topic.topic_arn}
                        },
                    )
                )

                # Add a policy to the queue to allow the S3 bucket to send messages
                sqs_queue.add_to_resource_policy(
                    aws_iam.PolicyStatement(
                        actions=["sqs:SendMessage", "sqs:ReceiveMessage"],
                        effect=aws_iam.Effect.ALLOW,
                        principals=[aws_iam.ArnPrincipal("*")],
                        resources=[sqs_queue.queue_arn],
                        conditions={
                            "ArnEquals": {"aws:SourceArn": s3_bucket.bucket_arn}
                        },
                    )
                )

                for level in config["VALID_DATA_LEVELS"]:
                    # If last level
                    if level == config["VALID_DATA_LEVELS"][-1]:
                        # Go directly to the SQS queue
                        bucket_notification = aws_s3_notifications.SqsDestination(
                            sqs_queue
                        )

                    # Create a filter for the SNS topic
                    s3_filter = aws_s3.NotificationKeyFilter(prefix=f"{level}/")

                    # Add an event notification to the bucket
                    s3_bucket.add_event_notification(
                        aws_s3.EventType.OBJECT_CREATED_COPY,
                        bucket_notification,
                        s3_filter,
                    )

                    # Add an event notification to the bucket
                    s3_bucket.add_event_notification(
                        aws_s3.EventType.OBJECT_CREATED_PUT,
                        bucket_notification,
                        s3_filter,
                    )

            apply_standard_tags(s3_bucket)
            logging.info(f"Created the {bucket} S3 Bucket")
            s3_buckets.append(s3_bucket)

        return s3_server_access_bucket, s3_buckets

    def _create_private_ecr_repos(self, config):
        private_ecr_repos = []
        for ecr_repo in config["ECR_PRIVATE_REPO_LIST"]:
            private_ecr_repo = aws_ecr.Repository(
                self,
                f"aws_sdc_{ecr_repo}_private_repo",
                repository_name=ecr_repo,
                removal_policy=RemovalPolicy.RETAIN,
            )

            self._apply_ecr_lifecycle_policy(private_ecr_repo)
            apply_standard_tags(private_ecr_repo)
            logging.info(f"Created the {ecr_repo} Private ECR Repo")
            private_ecr_repos.append(private_ecr_repo)

        return private_ecr_repos

    def _create_public_ecr_repos(self, config):
        public_ecr_repos = []
        for ecr_repo in config["ECR_PUBLIC_REPO_LIST"]:
            public_ecr_repo = aws_ecr.CfnPublicRepository(
                self,
                f"aws_sdc_{ecr_repo}_private_repo",
                repository_name=ecr_repo,
            )

            apply_standard_tags(public_ecr_repo)
            logging.info(f"Created the {ecr_repo} Public ECR Repo")
            public_ecr_repos.append(public_ecr_repo)

        return public_ecr_repos

    def _apply_ecr_lifecycle_policy(self, ecr_repository):
        """
        Apply common lifecycle rules to clean old images from ECR Repositories
        Note: Order does matter when creates Lifecycle Policies. For more info:
        https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html
        """

        ecr_repository.add_lifecycle_rule(
            description="Keeps images prefixed with version tag (e.i. v0.0.1)",
            tag_prefix_list=["v"],
            max_image_count=9999,
        )

        ecr_repository.add_lifecycle_rule(
            description="Keeps images prefixed with latest",
            tag_prefix_list=["latest"],
            max_image_count=9999,
        )

        ecr_repository.add_lifecycle_rule(max_image_age=Duration.days(30))
