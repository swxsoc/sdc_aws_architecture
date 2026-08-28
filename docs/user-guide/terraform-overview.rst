.. _terraform-overview:

Terraform Overview
==================
Terraform is used to define and provision all infrastructure in this repository. There are two main stacks:

* **Base infrastructure** in `base-infrastructure-terraform/`
* **Pipeline infrastructure** in `pipeline-infrastructure-terraform/`

Workspaces
----------
Pipeline infrastructure uses workspaces for environments and missions, for example:

* `dev-<mission>`
* `prod-<mission>`

Common Commands
---------------
Initialize:
.. code-block:: bash

    terraform init

Format:
.. code-block:: bash

    terraform fmt -recursive

Validate:
.. code-block:: bash

    terraform validate

Plan with a mission tfvars file:
.. code-block:: bash

    terraform plan -var-file=<mission>.tfvars

Apply with a mission tfvars file:
.. code-block:: bash

    terraform apply -var-file=<mission>.tfvars

Make Shortcuts
--------------
If you prefer Makefile shortcuts:
.. code-block:: bash

    make tf-fmt
    make tf-validate-base
    make tf-validate-pipeline
    make tf-plan-base
    make tf-apply-base
    make tf-plan-pipeline MISSION=<mission> ENV=dev
    make tf-apply-pipeline MISSION=<mission> ENV=dev

Notes
-----
Terraform state uses an S3 backend configured in each `main.tf`. You will need access to that bucket for real deployments.

CI runs formatting and lint checks only: `terraform fmt`, `terraform validate` (with `-backend=false`), `terraform test` (when tests are present), `tflint`, and Python `ruff format`/`ruff check` for docs. We do not run `terraform apply` in CI.

The CodeBuild deployment job requires ``MISSION`` (or the legacy
``MISSION_NAME``) to be set explicitly, for example ``MISSION=hermes``,
``MISSION=padre``, or ``MISSION=swxsoc_pipeline``. It selects the existing
``<env>-<mission>`` workspace, reads the selected mission's Terraform
variables, and resolves ECR image tags only for enabled Lambda functions that
are not using an explicit image URI override. An ``EXECUTOR`` image deployment
uses the base Terraform root and its ``default`` workspace instead.

Lambda image jobs must pass an immutable ``TAG`` and the ``LAMBDA_PIPELINE``.
Mission image jobs must also pass an explicit ``CDK_ENVIRONMENT`` of
``DEVELOPMENT`` or ``PRODUCTION``; executor jobs always use the base
``default`` workspace and need no environment override. CodeBuild creates a
saved, targeted plan for the triggering Lambda and refuses deletes,
replacements, or changes to unrelated resources. Direct architecture builds
use CodeBuild webhook/source metadata rather than local Git tags to determine
their source and environment.

Manual applies must pass immutable image-tag variables for every enabled
private-ECR Lambda (``pf_image_tag``, ``sf_image_tag``, ``af_image_tag``,
``cf_image_tag``, or ``ef_image_tag`` as appropriate). Do not deploy using the
mutable ``latest`` defaults. Review every plan before applying it. The project
should use a CodeBuild managed Linux image that supports buildspec runtime
selection for Python 3.12.

Secrets Manager Naming
----------------------
Secrets use the predictable mission-first path
``swxsoc/<environment>/<mission>/<service>/<secret>``. Path components are
lowercase, environments are ``dev`` or ``prod``, and underscores in mission
names are normalized to hyphens. For example:

* ``swxsoc/prod/hermes/processing/rds``
* ``swxsoc/dev/impax/processing/grafana``
* ``swxsoc/prod/swxsoc/executor/udl``

Terraform derives managed RDS and Grafana secret names from the selected
workspace and mission. The optional ``grafana_secret_name`` and
``udl_secret_name`` variables are escape hatches for an existing externally
managed secret; leave them empty to use the convention.

AWS Secrets Manager cannot rename a secret. A Terraform name change therefore
plans a replacement. Before applying a migration, create or copy externally
managed values at the new path, verify IAM access, and update every consumer.
Do not store secret values in Terraform variable files or version control.
