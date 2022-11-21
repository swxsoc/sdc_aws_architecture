#!/usr/bin/env python3
import os
import logging
import aws_cdk as cdk
from util import load_config, validate_config
from cdk_deployment.sdc_aws_pipeline_architecture import SDCAWSPipelineArchitectureStack
from cdk_deployment.sdc_aws_processing_lambda import SDCAWSProcessingLambdaStack
from cdk_deployment.sdc_aws_sorting_lambda import SDCAWSSortingLambdaStack

logging.basicConfig(level=logging.INFO)

# Loads config file
config = load_config()

# Validates config file
if not validate_config(config):
    logging.error("Invalid Config File")
    exit(1)

app = cdk.App()

# Initialize Deployment Stack
SDCAWSPipelineArchitectureStack(
    app,
    "SDCAWSPipelineArchitectureStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=config["DEPLOYMENT_REGION"]
    ),
    config=config,
)
logging.info("SDCAWSPipelineArchitectureStack synthesized successfully")

# Initialize Processing Lambda Stack
SDCAWSProcessingLambdaStack(
    app,
    "SDCAWSProcessingLambdaStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=config["DEPLOYMENT_REGION"]
    ),
    config=config,
)
logging.info("SDCAWSProcessingLambdaStack synthesized successfully")

# Initialize Sorting Lambda Stack
SDCAWSSortingLambdaStack(
    app,
    "SDCAWSSortingLambdaStack",
    env=cdk.Environment(
        account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=config["DEPLOYMENT_REGION"]
    ),
    config=config,
)
logging.info("SDCAWSSortingLambdaStack synthesized successfully")

# Synthesize Cloudformation Template
app.synth()
