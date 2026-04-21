.. _iam-overview:

AWS IAM Overview
================
AWS IAM is a service that helps you securely control access to AWS resources. You use IAM to control who is authenticated (signed in) and authorized (has permissions) to use resources. You can use groups to specify permissions for a collection of users, and you can use roles to define a set of permissions for one or more trusted entities (such as an EC2 instance, an application, or a service) to assume. For more information about IAM, see `What Is IAM? <http://docs.aws.amazon.com/IAM/latest/UserGuide/Welcome.html>`__

How we manage IAM via the Pipeline
----------------------------------
The pipeline defines IAM roles and policies directly in Terraform. Each Lambda or service role starts with the minimum required permissions and is then granted access to specific resources (S3 buckets, Timestream, Secrets Manager, etc.) via explicit policy attachments.

Timestream access is handled via a dedicated IAM policy resource that is attached to the relevant roles.

Learn More
----------
For more information about IAM, see `What Is IAM? <http://docs.aws.amazon.com/IAM/latest/UserGuide/Welcome.html>`__.

