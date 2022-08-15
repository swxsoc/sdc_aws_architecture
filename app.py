#!/usr/bin/env python3
import os

import aws_cdk as cdk

from cdk_deployment.sdc_aws_pipeline_architecture import SDCAWSPipelineArchitectureStack
from cdk_deployment.vars import DEPLOYMENT_REGION


app = cdk.App()

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
