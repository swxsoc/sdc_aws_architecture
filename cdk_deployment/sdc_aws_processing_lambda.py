import os
from aws_cdk import (
    Stack,
    aws_lambda,
    aws_ecr,
    aws_iam,
    Duration,
    aws_s3,
    aws_sns,
    aws_secretsmanager,
    aws_rds,
    aws_sns_subscriptions,
    aws_ec2,
    RemovalPolicy,
)
import json
from constructs import Construct
import logging
from util import apply_standard_tags, is_production


class SDCAWSProcessingLambdaStack(Stack):
    def __init__(
        self, scope: Construct, construct_id: str, config: dict, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.is_production = is_production(config)

        # ECR Repo Name
        repo_name = config["PROCESSING_LAMBDA_PRIVATE_ECR_NAME"]

        # Get SDC Processing Lambda ECR Repo
        ecr_repository = aws_ecr.Repository.from_repository_name(
            self, id=f"{repo_name}_repo", repository_name=repo_name
        )

        # Get time tag enviromental variable
        TAG = os.getenv("TAG") if os.getenv("TAG") is not None else "latest"

        # Create Secret
        rds_credentials_secret = self._create_secret()

        database_name = f"{'' if self.is_production else 'dev_'}hermes_db"

        # Create RDS Database
        if not os.getenv("DRY_RUN"):
            db_instance = self._create_rds_database(
                rds_credentials_secret, database_name
            )

        # Create Container Image ECR Function
        processing_function_name = (
            f"{config['PROCESSING_LAMBDA_PRIVATE_ECR_NAME']}_function"
        )

        sdc_aws_processing_function = aws_lambda.DockerImageFunction(
            scope=self,
            id=processing_function_name,
            function_name=processing_function_name,
            description=(
                "SWSOC Processing Lambda function deployed using AWS CDK Python"
            ),
            timeout=Duration.minutes(15),
            code=aws_lambda.DockerImageCode.from_ecr(ecr_repository, tag_or_digest=TAG),
            environment={
                "LAMBDA_ENVIRONMENT": config["DEPLOYMENT_ENVIRONMENT"],
                "RDS_SECRET_ARN": (
                    rds_credentials_secret.secret_arn
                    if not os.getenv("DRY_RUN")
                    else ""
                ),
                "RDS_HOST": (
                    db_instance.db_instance_endpoint_address
                    if not os.getenv("DRY_RUN")
                    else ""
                ),
                "RDS_PORT": str(
                    db_instance.db_instance_endpoint_port
                    if not os.getenv("DRY_RUN")
                    else ""
                ),
                "RDS_DATABASE": database_name,
            },
        )

        rds_credentials_secret.grant_read(sdc_aws_processing_function)

        # Give Lambda Read/Write Access to all Timestream Tables
        sdc_aws_processing_function.add_to_role_policy(
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

        # Give Lambda function read/write access to the RDS instance
        sdc_aws_processing_function.add_to_role_policy(
            aws_iam.PolicyStatement(
                effect=aws_iam.Effect.ALLOW,
                actions=[
                    "rds-data:ExecuteStatement",
                    "rds-data:BatchExecuteStatement",
                ],
                resources=[
                    db_instance.instance_arn if not os.getenv("DRY_RUN") else "*"
                ],
            )
        )

        # Grant Access to Repo
        ecr_repository.grant_pull_push(sdc_aws_processing_function)

        # Apply Standard Tags to CW Event
        apply_standard_tags(sdc_aws_processing_function)

        # Attach bucket event to lambda function with target
        for bucket in config["INSTR_TO_BUCKET_NAME"]:
            # Get the incoming bucket from S3
            lambda_bucket = aws_s3.Bucket.from_bucket_name(
                self, f"aws_sdc_{bucket}", bucket
            )
            lambda_bucket.grant_read_write(sdc_aws_processing_function)

            # Get the SNS Topic by name
            sns_topic = aws_sns.Topic.from_topic_arn(
                self,
                f"aws_sdc_{bucket}_data_level_sns_topic",
                (
                    f"arn:aws:sns:{config['DEPLOYMENT_REGION']}:"
                    f"{self.account}:{bucket}-sns-topic"
                ),
            )

            # Add Lambda as a subscriber to the SNS Topic
            sns_topic.add_subscription(
                aws_sns_subscriptions.LambdaSubscription(sdc_aws_processing_function)
            )

        logging.info("Function created successfully: %s", sdc_aws_processing_function)

    def _create_secret(self):
        credential_id = f"{'' if self.is_production else 'dev-'}RDSCredentialsSecret"
        # Create a secret to store the RDS credentials
        rds_credentials_secret = aws_secretsmanager.Secret(
            self,
            credential_id,
            description="RDS master user credentials for CDFTracker",
            generate_secret_string=aws_secretsmanager.SecretStringGenerator(
                secret_string_template=json.dumps({"username": "cdftracker_user"}),
                generate_string_key="password",
                exclude_characters='{}[]:;"<>?,./\\|`~!@#$%^&*()-=_+',
                password_length=20,
            ),
        )
        return rds_credentials_secret

    def _create_rds_database(self, rds_credentials_secret, database_name):
        # If environmental variable DRY_RUN create a new vpc, if not use from default
        vpc = aws_ec2.Vpc.from_lookup(self, "DefaultVPC", is_default=True)

        db_instance = aws_rds.DatabaseInstance(
            self,
            database_name,
            engine=aws_rds.DatabaseInstanceEngine.postgres(
                version=aws_rds.PostgresEngineVersion.VER_14
            ),
            instance_type=aws_ec2.InstanceType.of(
                aws_ec2.InstanceClass.T3, aws_ec2.InstanceSize.MICRO
            ),
            vpc=vpc,
            allocated_storage=30,
            storage_encrypted=False,
            multi_az=False,
            publicly_accessible=True,
            vpc_subnets=aws_ec2.SubnetSelection(subnet_type=aws_ec2.SubnetType.PUBLIC),
            auto_minor_version_upgrade=True,
            removal_policy=RemovalPolicy.RETAIN,
            deletion_protection=True,
            database_name=database_name,
            credentials=aws_rds.Credentials.from_secret(rds_credentials_secret),
        )

        return db_instance
