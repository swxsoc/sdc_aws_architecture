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

env_prefix = "Dev" if config["DEPLOYMENT_ENVIRONMENT"] != "PRODUCTION" else ""

pipeline_stack_name = f"{env_prefix}SDCAWSPipelineArchitectureStack"
processing_lambda_stack_name = f"{env_prefix}SDCAWSProcessingLambdaStack"
sorting_lambda_stack_name = f"{env_prefix}SDCAWSSortingLambdaStack"


def initialize_stack(stack_class, stack_name, app, config):
    stack = stack_class(
        app,
        stack_name,
        env=cdk.Environment(
            account=os.getenv("CDK_DEFAULT_ACCOUNT"), region=config["DEPLOYMENT_REGION"]
        ),
        config=config,
    )
    logging.info(f"{stack_name} synthesized successfully")
    return stack


# Initialize Deployment Stack
initialize_stack(SDCAWSPipelineArchitectureStack, pipeline_stack_name, app, config)

# Initialize Processing Lambda Stack
initialize_stack(SDCAWSProcessingLambdaStack, processing_lambda_stack_name, app, config)

# Initialize Sorting Lambda Stack
initialize_stack(SDCAWSSortingLambdaStack, sorting_lambda_stack_name, app, config)

# Synthesize Cloudformation Template
app.synth()
