#!/usr/bin/env python3
import os

import aws_cdk as cdk

from cdk_deployment.sdc_aws_pipeline_architecture import SDCAWSPipelineArchitectureStack


app = cdk.App()
SDCAWSPipelineArchitectureStack(
    app,
    "SDCAWSPipelineArchitectureStack",
    env=cdk.Environment(account=os.getenv("CDK_DEFAULT_ACCOUNT"), region="us-east-1"),
)

app.synth()
