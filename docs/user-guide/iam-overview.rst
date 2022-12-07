.. _iam-overview:

AWS IAM Overview
================
AWS IAM is a service that helps you securely control access to AWS resources. You use IAM to control who is authenticated (signed in) and authorized (has permissions) to use resources. You can use groups to specify permissions for a collection of users, and you can use roles to define a set of permissions for one or more trusted entities (such as an EC2 instance, an application, or a service) to assume. For more information about IAM, see `What Is IAM? <http://docs.aws.amazon.com/IAM/latest/UserGuide/Welcome.html>`__

How we manage IAM via the Pipeline
----------------------------------
We have set up the pipeline so that it automatically configures the necessary permissions for each resource to interact with each other. Each CDK resource starts out with the bare minimum amount of permissions that is needed and then is granted access to the required resources via CDK 'grant' helper functions. 

The only IAM policy that is defined without a helper function is the policy that grants read/write access to the Timestream database. This is because the CDK does not currently have a 'grant' helper function for Timestream.

Learn More
----------
For more information about IAM, see `What Is IAM? <http://docs.aws.amazon.com/IAM/latest/UserGuide/Welcome.html>`__.


