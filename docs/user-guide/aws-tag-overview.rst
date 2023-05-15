.. _aws-tag-overview:

AWS Tagging Overview
====================
AWS Tags are used to organize and categorize your AWS resources. You can use tags to manage access to your resources, to organize your resources, and to provide cost allocation information. For more information, see `Tagging AWS Resources <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Tags.html>`__.

How we use Tags
---------------
We use tags to organize and categorize your AWS resources. We use the following tags:

- **Purpose** : This is an indicator on the purpose of the resource. Right now it is defaulted to 'SWSOC Pipeline'.

- **Last Modified** : This is the date and time the stack was last modified.

- **Environment** : This is the environment the stack is deployed to. It is defaulted to 'PRODUCTION' because the development pipeline is still being worked on.

- **Version** : This is the version of the stack that is deployed, this will indicate which release of the stack is being used.

Learn More
----------
For more information on AWS Tags, see `Tagging AWS Resources <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Tags.html>`__.