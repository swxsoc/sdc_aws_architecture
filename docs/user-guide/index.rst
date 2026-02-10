.. _guide:

User's Guide
================

Welcome to our User Guide. This guide will help you get the pipeline set up and running on your AWS account using Terraform.


Prerequisites
-------------
* An AWS account
* AWS CLI installed and configured
* Terraform 1.x installed
* Docker installed (for building and pushing Lambda container images)
* Python 3.8+ (only needed for building docs or running helper scripts)

Getting Started
---------------
This guide assumes you have an AWS account with permissions to create and manage resources. If you are new to AWS, see https://aws.amazon.com/getting-started/.

Step 1: Download the Code
-------------------------
Clone the repository:
    git clone https://github.com/HERMES-SOC/sdc_aws_pipeline_architecture.git && cd sdc_aws_pipeline_architecture

Step 2: Configure AWS Credentials
---------------------------------
Make sure the AWS CLI is configured with credentials that can create resources:
    aws configure

Step 3: Update Terraform Variables
----------------------------------
There are two sets of Terraform configs:

* **Base infrastructure**: `base-infrastructure-terraform/`
* **Pipeline infrastructure**: `pipeline-infrastructure-terraform/`

Edit the mission-specific tfvars file in `pipeline-infrastructure-terraform/` (for example, `padre.tfvars` or `hermes.tfvars`) and ensure:

* `mission_name` is correct
* `instrument_names` is correct
* S3 bucket names are globally unique
* Any optional values (e.g., uploader roles, secrets, image tags) match your environment

If you are bootstrapping a new mission before images or secrets exist, you can:

* Set `enable_*_lambda = false` to skip creating Lambdas until images are pushed
* Set `enable_grafana_secret = false` if the Grafana secret does not exist yet

Optional: Build Docs Locally
----------------------------
If you want to build the documentation locally:
    python3 -m venv .venv
    source .venv/bin/activate
    python3 -m pip install -r requirements.txt
    make html

Step 4: Deploy Base Infrastructure
----------------------------------
Deploy shared resources first:
    cd base-infrastructure-terraform
    terraform init
    terraform plan
    terraform apply

Step 5: Deploy Pipeline Infrastructure
--------------------------------------
Deploy the mission pipeline using workspaces:
    cd ../pipeline-infrastructure-terraform
    terraform workspace new dev-<mission>
    terraform workspace select dev-<mission>
    terraform init
    terraform plan -var-file=<mission>.tfvars
    terraform apply -var-file=<mission>.tfvars

Use `dev-<mission>` for development and `prod-<mission>` for production. The workspace prefix controls resource naming.

Step 6: Build and Push Lambda Images
------------------------------------
The Sorting, Processing, and Artifacts Lambdas are deployed from ECR images. Build and push images to the ECR repos created by Terraform, then re-run `terraform apply` to pick up the new image tags if needed.

A typical flow looks like:

    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account_id>.dkr.ecr.<region>.amazonaws.com
    docker build -t <repo_name> .
    docker tag <repo_name>:latest <account_id>.dkr.ecr.<region>.amazonaws.com/<repo_name>:latest
    docker push <account_id>.dkr.ecr.<region>.amazonaws.com/<repo_name>:latest

Step 7: Verify Resources
------------------------
Use the AWS Console or Terraform state to confirm buckets, topics/queues, Lambdas, and databases are created.

.. Note::
    If you want to bootstrap infrastructure before images exist, you can disable Lambda creation using `enable_*_lambda` variables and enable them after images are pushed.

.. Note::
    Grafana/Loki and other observability systems are not managed by this repo.

Mission Deploy Checklist
------------------------
Use this checklist for each new mission deployment:

* Confirm AWS credentials and target account/region
* Create or update the mission tfvars file with unique S3 bucket names
* Create/select the correct workspace (`dev-<mission>` or `prod-<mission>`)
* Run `terraform plan -var-file=<mission>.tfvars` and confirm only mission resources are changing
* Apply base infrastructure (first time only)
* Apply pipeline infrastructure for the mission
* Push Lambda images to the mission ECR repos
* Enable Lambdas (`enable_*_lambda = true`) and re-apply if they were initially disabled
* Verify S3 buckets, SNS/SQS, Lambdas, Timestream, and RDS in AWS

Where to go from here:
----------------------
.. toctree::
   :maxdepth: 6

   terraform-overview
   timestream-overview
   docker-overview
   iam-overview
   aws-tag-overview
