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

CI runs formatting and lint checks only: `terraform fmt`, `terraform validate` (with `-backend=false`), `terraform test` (when tests are present), `tflint`, and Python `black`/`flake8` for docs. We do not run `terraform apply` in CI.
