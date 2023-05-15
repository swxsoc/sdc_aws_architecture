.. _repo_guide:

Repository Guide
================

This guide is to help navigate through the different repositories that are required for the SDC AWS Pipeline. The use of each repository is explained in the following sections. 


.. _sdc_aws_pipeline_architecture:

SDC AWS Pipeline Architecture
-----------------------------
This repository is what deploys all the cloud resources required for the SDC AWS Pipeline. It makes use of AWS Cloud Development Kit (CDK) to deploy the resources. The repo includes three different CDK stacks (located within the `cdk_deployment` folder) of cloud resources that to AWS:

- **SDCAWSPipelineArchitectureStack** : a stack that deploys the underlying infrastructure (S3 Buckets, ECR repositories, Timestream Databases, etc).
- **SDCAWSSortingLambdaStack** : a stack that deploys the SDC Sorting Lambda Function (as a zip deployment based off the sdc_aws_sorting_lambda repo).
- **SDCAWSProcessingLambdaStack** : a stack that deploys the SDC Processing Lambda Function (as a container image deployment based off the sdc_aws_processing_lambda repo).

Link to the `GitHub repository for Pipeline <https://github.com/HERMES-SOC/sdc_aws_pipeline_architecture>`_.


.. Note:: 
    
    The **SDCAWSSortingLambdaStack** and **SDCAWSProcessingLambdaStack** CDK stacks are dependent on the **SDCAWSPipelineArchitectureStack** CDK stack. 
    
    Also the **SDCAWSProcessingLambdaStack** stack is dependent on the SDC AWS Base Image being built and pushed to the Public ECR Repo after, which is currently being handled within it's own `GitHub repository <https://github.com/HERMES-SOC/sdc_aws_base_docker_image>`_ .

.. _sdc_aws_base_docker_image:

SDC AWS Base Docker Image
-------------------------
This repo contains a dockerfile and Python requirements file that is used to build the SDC AWS Base Docker Image. This image is used throughout the different `.devcontainer` repositories (hermes_core and instrument packages) as well as the base image for the Lambda Processing function within the file processing pipeline. 

The image is built, tested and pushed to the public ECR repository automatically through a CI/CD Pipeline allowing anyone to make changes to the base image. This repository is currently configured to run tests and linting workflows with `GitHub Actions <https://docs.github.com/en/actions/learn-github-actions/understanding-github-actions>`_ on Pull Requests. Once the Pull Request is approved and merged into main it then triggers an AWS CodeBuild workflow to test, build and push the image to the Public ECR repository.

Link to the `GitHub repository for Base Docker Image <https://github.com/HERMES-SOC/sdc_aws_base_docker_image>`_.

Link to the `Repository Documentation <https://sdc-aws-base-docker-image.readthedocs.io/en/main/>`_.

.. Note::

    It is possible to build the image locally using the `Dockerfile` and `requirements.txt` files and then manually push the image to the Public ECR repository. However, make sure you have deployed the **SDCAWSPipelineArchitectureStack** CDK Stack first as this stack includes the creation of the Public ECR Repo.

.. _sdc_aws_sorting_lambda:

SDC AWS Sorting Lambda
----------------------

This repo contains the source code for the SDC Sorting Lambda Function. This is the function that is triggered whenever a new file is uploaded into the Incoming S3 Bucket that is deployed by the pipeline stack (**SDCAWSPipelineArchitectureStack**). This function copies the file into the correct instrument bucket (if it is a valid instrument file) which causes the SDC Processing Lambda Function to be triggered on that instrument bucket. If it is not a valid file it then skips the file and moves onto the next file to check and sort. The incoming bucket in this case becomes a duplicate of the folder that is being synced from the SDC external server, which serves as a backup of the files. Bucket versioning has been enabled as well just in case duplicates are uploaded into the bucket (Which should not be the case but it's a good failsafe). Also this Lambda function logs the file name and the time it was uploaded into the incoming bucket into a Timestream database and has a set cron schedule of every 12 hours to check for any files that were not sorted for whatever reason.

The zip deployment of this function is zipped up and uploaded to the Sorting Lambda S3 Bucket deployed by the pipeline stack (**SDCAWSPipelineArchitectureStack**) via CI/CD. This is then deployed as a Lambda Function by the **SDCAWSSortingLambdaStack** CDK stack after all of it's CI/CD tests have been passed. For CI/CD there is currently a GitHub Actions workflow that runs on Pull Requests and then when pushed to main triggers an AWS CodeBuild workflow to test, build and push the zip deployment to the Sorting Lambda S3 Bucket.

Link to the `GitHub repository for Sorting Function <https://github.com/HERMES-SOC/sdc_aws_sorting_lambda>`_.

**Documentation for this Repo Under Construction** 

.. Note::

    It is possible to zip the image locally and then manually push the zip file into the sorting lambda bucket, then deploy using the **SDCAWSSortingLambdaStack** within this repo. However, make sure you have deployed the **SDCAWSPipelineArchitectureStack** CDK Stack first as this stack includes the creation of the sorting bucket. Also since the **SDCAWSSortingLambdaStack** is triggered by CI/CD, you must specify the name of the zip file to be deployed as the environment variable `ZIP_NAME`.

.. _sdc_aws_processing_lambda:

SDC AWS Processing Lambda
-------------------------

This repo contains the source code for the SDC Processing Lambda Function. This is the function that is triggered whenever a new file is uploaded into an instrument bucket that is deployed by the pipeline stack (**SDCAWSPipelineArchitectureStack**). This function then processes the file to the next valid data level (dependent on **VALID_DATA_LEVELS** variable defined in the config.yaml of this repo) and adds the new processed data into the correct directory structure within the instrument bucket. If the calibration file does not exist it then terminates processing that file. This function is also set to run every 12 hours to check for any files that were not processed, this is so that if a new calibration file is made available it will then process any files that were not processed before. This function also logs the file name and the time it was uploaded into the instrument bucket into a Timestream database.

The container image deployment of this function is built and pushed to the Processing Lambda ECR Repo deployed by the pipeline stack (**SDCAWSPipelineArchitectureStack**) via CI/CD. This is then deployed as a Lambda Function by the **SDCAWSProcessingLambdaStack** CDK stack after all of it's CI/CD tests have been passed. For CI/CD there is currently a GitHub Actions workflow that runs on Pull Requests and then when pushed to main triggers an AWS CodeBuild workflow to test, build and push the container image to the Processing Lambda ECR Repo.

Link to the `GitHub repository for Processing Function <https://github.com/HERMES-SOC/sdc_aws_processing_lambda>`_.

**Documentation for this Repo Under Construction**

.. Note::

    It is possible to build the image locally and then manually push the image to the Processing Lambda ECR Repo, then deploy using the **SDCAWSProcessingLambdaStack** within this repo. However, make sure you have deployed the **SDCAWSPipelineArchitectureStack** CDK Stack first as this stack includes the creation of the processing ECR Repo.


