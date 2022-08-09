#!/usr/bin/env python3
import os

import aws_cdk as cdk

from cdk_deployment.sdc_aws_pipeline_architecture import SDCAWSPipelineArchitectureStack


app = cdk.App()

# Region that the stack will be deployed to
DEPLOYMENT_REGION = "us-east-1"

# Environment Name
environment_name = (
    "SDCAWSPipelineArchitectureStack"
    if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION"
    else "Dev-SDCAWSPipelineArchitectureStack"
)

# Initialize Deployment Stack
SDCAWSPipelineArchitectureStack(
    app,
    environment_name,
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=DEPLOYMENT_REGION
    ),
)

# Synthesize Cloudformation Template
app.synth()
