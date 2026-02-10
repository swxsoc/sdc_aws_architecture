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
    terraform init

Format:
    terraform fmt -recursive

Validate:
    terraform validate

Plan with a mission tfvars file:
    terraform plan -var-file=<mission>.tfvars

Apply with a mission tfvars file:
    terraform apply -var-file=<mission>.tfvars

Notes
-----
Terraform state uses an S3 backend configured in each `main.tf`. You will need access to that bucket for real deployments.

We do not run `terraform apply` in CI. Validation and formatting checks are the only automated checks by default.
