.. _guide:

User's Guide
================

Welcome to our User Guide. This guide will help you to get started with downloading this code and getting the pipeline set-up and running on your own AWS account. It will walk through each step of the process and provide you with the necessary information to get started.


Prerequisites
-------------
* An AWS account
* AWS CLI installed and configured
* AWS Cloud Development Kit (CDK) 2.0 installed on your machine
* Python 3.7 or higher
* Node.js 10.3.0 or higher
* Docker installed on your machine 

Getting Started
---------------
This guide assumes that you have already set up an AWS account and have the necessary permissions to create and manage AWS resources. If you do not have an AWS account, you can sign up for one at https://aws.amazon.com/. If you are new to AWS, you can find a number of resources to help you get started at https://aws.amazon.com/getting-started/.

It also walks through the steps that would be handled by CI/CD if you were to set it up as part of your project. If you are not familiar with CI/CD, you can find a number of resources to help you get started at https://aws.amazon.com/devops/continuous-delivery/.



Step 1: Download the Code
-------------------------
The first step is to download the code from GitHub. You can do this by running the following command:
    git clone https://github.com/HERMES-SOC/sdc_aws_pipeline_architecture.git && cd sdc_aws_pipeline_architecture

This will create a directory called sdc_aws_pipeline_architecture in your current directory. This directory contains all of the code that you will need to run the pipeline.


Step 2: Install dependencies for project
----------------------------------------
The next step is to install the dependencies for the project. You can do this by running the following command:
    pip install -r requirements.txt

.. Note:: 
    As defined in the Prerequisites, it is assumed you have set-up your AWS CLI with the appropriate keys and installed CDK via npm:
        npm install -g aws-cdk


Step 3: Modify config file to fit your naming scheme
--------------------------------------------------------
This is an important step because S3 Buckets are unique, so if you try to deploy using the default names it will fail because they have already been created. Go into the the **config.yaml** file, and at the minimum modify the Mission Name (because it is used to generate the intrument bucket names) and the different Bucket Names variables to fit your needs. S3 Bucket names are unique across AWS so the names you configure must be unique as well, it will fail on deployment if there is already a bucket that exists with the same name. 


Step 4: Deploy the **SDCAWSPipelineArchitectureStack** Stack using CDK
-----------------------------------------------------------------------
Deploy the **SDCAWSPipelineArchitectureStack** with CDK.
    cdk deploy SDCAWSPipelineArchitectureStack

.. Warning::
    If the deployment fails for some reason, and S3 Buckets and the Private ECR repo has been deployed already you will need to go into AWS and manually delete the created resources before redeploying. We have set those resources to be retained on CloudFormation Stack deletion to prevent any accidental deletions in the future.


Step 5: Build and Push the Lambda Function into the S3 Bucket
---------------------------------------------------------------
First clone the Sorting Lambda Function repo,
    cd .. && git clone git@github.com:HERMES-SOC/sdc_aws_sorting_lambda.git && cd sdc_aws_sorting_lambda

Then install the dependencies into the lambda function folder
    pip install     --platform manylinux2014_x86_64     --target=lambda_function     --implementation cp     --python 3.9     --only-binary=:all: --upgrade     -r requirements.txt 

Then zip and push to the S3 Sorting Lambda Function Bucket
    export ZIP_NAME=sorting_function_$(date +%s).zip && cd lambda_function && zip -r $ZIP_NAME .

Then push to the S3 Sorting Lambda Sorting Bucket
    aws s3 cp $ZIP_NAME s3://{sorting lambda bucket}


Step 6: Deploy the **SDCAWSSortingLambdaStack** Stack using CDK
------------------------------------------------------------------
Go back into the sdc_aws_pipeline_architecture repository you have cloned
    cd ../../sdc_aws_pipeline_architecture

Now that you've created the lambda function build artifact and uploaded it to the correct S3 bucket, you can now deploy it with
    cdk deploy SDCAWSSortingLambdaStack


Step 7: Build and Push Processing Lambda Function into ECR Repo
---------------------------------------------------------------------
First clone the Processing Lambda Function repo,
    cd .. && git clone git@github.com:HERMES-SOC/sdc_aws_processing_lambda.git && cd sdc_aws_processing_lambda/lambda_function

Then login to your Private ECR Repo
    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin {your_aws_account_number}.dkr.ecr.{DEPLOYMENT_REGION}.amazonaws.com

Build the docker image
    docker build -t sdc_aws_processing_lambda .

Tag the image
    docker tag sdc_aws_processing_lambda:latest {your_aws_account_number}.dkr.ecr.{DEPLOYMENT_REGION}.amazonaws.com/sdc_aws_processing_lambda:latest

Push to ECR
    docker push {your_aws_account_number}.dkr.ecr.{DEPLOYMENT_REGION}.amazonaws.com/sdc_aws_processing_lambda:latest


Step 8: Deploy the **SDCAWSProcessingLambdaStack** Stack using CDK
------------------------------------------------------------------
Go back into the sdc_aws_pipeline_architecture repository you have cloned
    cd ../../sdc_aws_pipeline_architecture

Now that you've created the lambda function image and uploaded it to the ECR, you can now deploy it with
    cdk deploy SDCAWSProcessingLambdaStack


Step 9: Verify the three different Stacks that compose the pipeline are up and running
------------------------------------------------------------------------------------------------
In your AWS console you can go into the CloudFormation service, in the deployment region you specified you should see the 3 different stacks were created successfully. You can click on each stack to view the different resources that were deployed successfully. You can now make use of the pipeline as long as you have valid mission core and instrument packages configured correctly. Check out how we've set-up our `hermes_core <https://github.com/HERMES-SOC/hermes_core>`_ and one of our `heremes_instrument <https://github.com/HERMES-SOC/hermes_eea>`_ packages here for refernce.

.. Note::
    The only other indirect part of the pipeline that is not included is the support systems that helps show the visibility of the pipeline. Which is mostly the Grafana and Loki deployment.

Where to go from here:
----------------------
.. toctree::
   :maxdepth: 6

   cdk-overview
   timestream-overview
   docker-overview
   iam-overview
   aws-tag-overview