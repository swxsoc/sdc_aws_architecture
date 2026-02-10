.. _repo_guide:

Repository Guide
================

This guide helps navigate the repositories required for the SDC AWS Pipeline. The use of each repository is explained below.


.. _sdc_aws_pipeline_architecture:

SDC AWS Pipeline Architecture
-----------------------------
This repository deploys all cloud resources required for the SDC AWS Pipeline using Terraform.

There are two Terraform entry points:

* **Base infrastructure** (`base-infrastructure-terraform/`): shared resources used across missions.
* **Pipeline infrastructure** (`pipeline-infrastructure-terraform/`): mission-specific resources (S3 buckets, ECR repos, Timestream, RDS, Lambdas, SNS/SQS, IAM, etc.).

Each mission is configured using a tfvars file (for example, `padre.tfvars`, `hermes.tfvars`) and a workspace per environment (for example, `dev-<mission>` and `prod-<mission>`).

Link to the `GitHub repository for Pipeline <https://github.com/HERMES-SOC/sdc_aws_pipeline_architecture>`_.

.. Note::

    Deploy base infrastructure first, then deploy pipeline infrastructure for each mission. Lambda images must be pushed to ECR before enabling or updating the corresponding Lambda functions.

.. _sdc_aws_base_docker_image:

SDC AWS Base Docker Image
-------------------------
This repo contains the Dockerfile and Python requirements for the SDC AWS Base Docker Image. The image is used throughout the different `.devcontainer` repositories (hermes_core and instrument packages) and as a base for the Lambda Processing function.

The image is built, tested, and pushed to a public ECR repository via CI/CD. Changes are validated with GitHub Actions on pull requests, and builds are pushed after merge.

Link to the `GitHub repository for Base Docker Image <https://github.com/HERMES-SOC/sdc_aws_base_docker_image>`_.
Link to the `Repository Documentation <https://sdc-aws-base-docker-image.readthedocs.io/en/main/>`_.

.. Note::

    Deploy pipeline infrastructure before attempting to push to the public ECR repository created by Terraform.

.. _sdc_aws_sorting_lambda:

SDC AWS Sorting Lambda
----------------------
This repo contains the source code for the SDC Sorting Lambda Function. The function is triggered when files land in the incoming S3 bucket and moves valid files into the correct instrument bucket.

The Lambda is deployed from a container image stored in the mission ECR repository created by Terraform. Build and push the image, then run `terraform apply` in `pipeline-infrastructure-terraform/` to update the Lambda image.

Link to the `GitHub repository for Sorting Function <https://github.com/HERMES-SOC/sdc_aws_sorting_lambda>`_.

**Documentation for this Repo Under Construction**

.. _sdc_aws_processing_lambda:

SDC AWS Processing Lambda
-------------------------
This repo contains the source code for the SDC Processing Lambda Function. The function is triggered when files land in instrument buckets and processes them to the next valid data level.

The Lambda is deployed from a container image stored in the mission ECR repository created by Terraform. Build and push the image, then run `terraform apply` in `pipeline-infrastructure-terraform/` to update the Lambda image.

Link to the `GitHub repository for Processing Function <https://github.com/HERMES-SOC/sdc_aws_processing_lambda>`_.

**Documentation for this Repo Under Construction**
