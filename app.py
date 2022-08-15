#!/usr/bin/env python3
import os

import aws_cdk as cdk

from cdk_deployment.sdc_aws_pipeline_architecture import SDCAWSPipelineArchitectureStack
from cdk_deployment.sdc_aws_processing_lambda import SDCAWSProcessingLambdaStack
from cdk_deployment.sdc_aws_sorting_lambda import SDCAWSSortingLambdaStack

from cdk_deployment.vars import DEPLOYMENT_REGION


app = cdk.App()


# Initialize Deployment Stack
SDCAWSPipelineArchitectureStack(
    app,
    "SDCAWSPipelineArchitectureStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=DEPLOYMENT_REGION
    ),
)

# Initialize Processing Lambda Stack
SDCAWSProcessingLambdaStack(
    app,
    "SDCAWSProcessingLambdaStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=DEPLOYMENT_REGION
    ),
)

# Initialize Sorting Lambda Stack
SDCAWSSortingLambdaStack(
    app,
    "SDCAWSSortingLambdaStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=DEPLOYMENT_REGION
    ),
)

# Synthesize Cloudformation Template
app.synth()
