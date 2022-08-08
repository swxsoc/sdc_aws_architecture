#!/usr/bin/env python3
import os

import aws_cdk as cdk

from cdk_deployment.sdc_aws_pipeline_architecture import SDCAWSPipelineArchitectureStack


app = cdk.App()

DEPLOYMENT_REGION = "us-east-1"

if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION":
    SDCAWSPipelineArchitectureStack(
        app,
        "SDCAWSPipelineArchitectureStack",
        env=cdk.Environment(
            account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=DEPLOYMENT_REGION
        ),
    )
else:
    SDCAWSPipelineArchitectureStack(
        app,
        "SDCAWSPipelineArchitectureStack-dev",
        env=cdk.Environment(
            account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=DEPLOYMENT_REGION
        ),
    )

app.synth()
