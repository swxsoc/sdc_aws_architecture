.. _aws-tag-overview:

AWS Tagging Overview
====================
AWS Tags are used to organize and categorize your AWS resources. You can use tags to manage access to your resources, to organize your resources, and to provide cost allocation information. For more information, see `Tagging AWS Resources <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Tags.html>`__.

How we use Tags
---------------
We use tags to organize and categorize AWS resources created by Terraform.
Provider default tags apply the complete common tag set to every supported
resource:

- **Mission** : The owning mission or ``swxsoc`` for base infrastructure.

- **Service** : Shared resources use the stack service. Component resources
  override it with ``executor``, ``processing``, ``sorting``, ``artifacts``,
  ``concating``, or ``container-base``.

- **Environment** : This is derived from the selected workspace. `dev-<mission>` workspaces use `Development`; `prod-<mission>` workspaces use `Production`.

- **Purpose** : This identifies the resource group. Base infrastructure uses `SWSOC Base Infrastructure`; pipeline infrastructure uses the `resource_purpose` Terraform variable, which defaults to `SWSOC Pipeline`.

- **Project** : This identifies the owning project or mission. Base infrastructure uses `soc_name`; pipeline infrastructure uses `mission_name`.

- **ManagedBy** : Terraform-managed resources use the stable value
  ``terraform``. Externally seeded secrets use ``external``.

Learn More
----------
For more information on AWS Tags, see `Tagging AWS Resources <http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Tags.html>`__.
