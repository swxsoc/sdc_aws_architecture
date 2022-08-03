from aws_cdk import Stack, aws_s3
from constructs import Construct
from . import vars
import logging


class SDCAWSPipelineArchitectureStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # Iterate through the S3 Buckets List and Create the Buckets
        for bucket in vars.BUCKETS:

            s3_bucket = aws_s3.Bucket(
                self, f"aws_sdc_{bucket}_bucket", bucket_name=bucket
            )

            logging.info(f"Created the {s3_bucket} S3 Bucket")
