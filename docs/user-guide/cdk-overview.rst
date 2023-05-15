.. _cdk-overview:

AWS Cloud Development Kit (AWS CDK) Overview
============================================
The AWS Cloud Development Kit (AWS CDK) is an open-source software development framework to define cloud infrastructure in code and provision it through AWS CloudFormation. It includes a set of libraries for AWS services and third-party construct libraries, which are open-source extensions that implement infrastructure patterns, with the goal of making it easier to set up best practices.

How to install CDK
-------------------
For the most up-to-date installation of CDK, follow the instructions in the official AWS Docs `here <https://docs.aws.amazon.com/cdk/v2/guide/getting_started.html>`_.

How we use CDK
-------------------
We utilize CDK to deploy all of our infrastructure. We've divided into our infrastructure into three stacks, **SDCAWSPipelineArchitectureStack**, **SDCAWSSortingLambdaStack**, **SDCAWSProcessingLambdaStack**. With the last two stacks being dependent on the first. Each stack is currently deployed via a CI/CD pipeline that has been set-up via AWS CodeBuild.

Basic CDK Use
-------------------
After successfully installing CDK you can then utilize the different commands that are available:

To Verify Stacks are Valid in the CDK Project you can do a: 
    cdk ls

To Deploy a specific cdk stack or update one that has already been deployed you can perform a:
    cdk deploy {Stack_Name}

Learn More
-------------------
This is just a basic overview of CDK, to learn more refer to the official documentation `here <https://docs.aws.amazon.com/cdk/v2/guide/getting_started.html>`_.