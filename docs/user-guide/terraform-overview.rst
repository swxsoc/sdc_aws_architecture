.. _terraform-overview:

Terraform Overview
==================
Terraform is used to define and provision all infrastructure in this repository. There are three main stacks:

* **Base infrastructure** in `base-infrastructure-terraform/`
* **Pipeline infrastructure** in `pipeline-infrastructure-terraform/`
* **Deployment infrastructure** in `deployment-infrastructure-terraform/`

Workspaces
----------
Pipeline infrastructure uses workspaces for environments and missions, for example:

* `dev-<mission>`
* `prod-<mission>`

The pipeline root refuses to plan in the ``default`` workspace. That workspace
is reserved for base infrastructure; always select an explicit mission and
environment before planning.

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
    make tf-validate-deployment
    make tf-plan-base
    make tf-apply-base
    make tf-plan-pipeline MISSION=<mission> ENV=dev
    make tf-apply-pipeline MISSION=<mission> ENV=dev
    make tf-plan-deployment
    make tf-apply-deployment

Notes
-----
Terraform state uses an S3 backend configured in each `main.tf`. The deployment
root has its own state key. All roots use native S3 lockfiles, so execution
roles need access to the state object and matching ``.tflock`` object.

CI runs formatting and lint checks only: `terraform fmt`, `terraform validate` (with `-backend=false`), `terraform test` (when tests are present), `tflint`, and Python `ruff format`/`ruff check` for docs. We do not run `terraform apply` in CI.

The CodeBuild deployment job requires ``MISSION`` (or the legacy
``MISSION_NAME``) to be set explicitly, for example ``MISSION=hermes``,
``MISSION=padre``, or ``MISSION=swxsoc_pipeline``. It selects the existing
``<env>-<mission>`` workspace, reads the selected mission's Terraform
variables, and resolves ECR image tags only for enabled Lambda functions that
are not using an explicit image URI override. ``EXECUTOR`` and ``ALERT``
image deployments use the base Terraform root and its ``default`` workspace
instead, and are started by the dedicated
``build_swxsoc_sdc_aws_base_architecture`` project.

Lambda image jobs must pass an immutable ``TAG`` and the ``LAMBDA_PIPELINE``.
Mission image jobs must also pass an explicit ``CDK_ENVIRONMENT`` of
``DEVELOPMENT`` or ``PRODUCTION``; executor and alert jobs always use the base
``default`` workspace and need no environment override. CodeBuild creates a
saved, targeted plan for the triggering Lambda and refuses deletes,
replacements, or changes to unrelated resources. Direct architecture builds
use CodeBuild webhook/source metadata rather than local Git tags to determine
their source and environment.

Manual applies must pass immutable image-tag variables for every enabled
private-ECR Lambda (``pf_image_tag``, ``sf_image_tag``, ``af_image_tag``,
``cf_image_tag``, ``ef_image_tag``, or ``alert_image_tag`` as appropriate). Terraform rejects a
missing selection or the mutable ``latest`` tag. Review every plan before applying it. The project
should use a CodeBuild managed Linux image that supports buildspec runtime
selection for Python 3.12.

CodeBuild ownership
-------------------

The deployment root adopts all 33 existing CodeBuild projects through
declarative ``import`` blocks and adds the dedicated
``build_swxsoc_sdc_aws_base_architecture`` project, for 34 managed projects.
It standardizes repository buildspecs, current managed images, Docker
privileged mode for container builds, concurrency, GitHub status reporting,
predictable service roles, explicit 90-day log groups, and cost tags.
Architecture webhooks run pull-request validation only. Main and tag events on
image repositories build the image and explicitly start the matching
architecture project; the executor and alert images start the base
architecture project.

The nine ``trigger_rebuild_*`` dependency projects and
``padre-reprocessing-requests`` are managed as support projects with generated
buildspecs and least-privilege roles. Dependency triggers rebuild their
declared mission base images for ``DEVELOPMENT`` on ``main`` pushes and
``PRODUCTION`` on release tags, and skip every other branch.
``trigger_rebuild_swxsoc`` fans out to all four mission base images.

The first apply of each root adopts existing resources: the deployment root
imports projects, webhooks, and log groups; the base root imports the alert
ECR repository, Lambda, EventBridge rule, permission, target, and both base
Lambda log groups; each pipeline workspace imports its Lambda log groups. Review
every saved plan for deletes or replacements before applying, and apply
manually. Nothing in this repository applies these roots automatically.

To add a mission, add one object to ``local.missions`` in
``deployment-infrastructure-terraform/codebuild.tf``. Supply its base-image
repository, connection ARN, and enabled Lambda components; Terraform generates
the project, role, policy, webhook, and complete tag map.

Secrets Manager Naming
----------------------
Secrets use the predictable mission-first path
``swxsoc/<environment>/<mission>/<service>/<secret>``. Path components are
lowercase, environments are ``dev`` or ``prod``, and underscores in mission
names are normalized to hyphens. For example:

* ``swxsoc/prod/hermes/processing/rds``
* ``swxsoc/dev/impax/processing/grafana``
* ``swxsoc/prod/swxsoc/executor/udl``
* ``swxsoc/dev/swxsoc-pipeline/communications/mattermost``

Terraform derives managed RDS and Grafana secret names from the selected
workspace and mission. The optional ``grafana_secret_name`` and
``udl_secret_name`` variables are escape hatches for an existing externally
managed secret; leave them empty to use the convention.

The checked-in base tfvars temporarily selects the legacy Grafana, UDL, and
``gdc_test_kafka`` GCN names so executor and alert image deployments remain
safe during migration, and ``hermes.tfvars`` and ``padre.tfvars`` pin the
legacy ``grafana-credentials`` name for the same reason. Remove an override
only after the mission-first value exists; the Terraform-managed Grafana secret
also requires a reviewed state migration rather than a blind replacement.

AWS Secrets Manager cannot rename a secret. A Terraform name change therefore
plans a replacement. Before applying a migration, create or copy externally
managed values at the new path, verify IAM access, and update every consumer.
Do not store secret values in Terraform variable files or version control.
Managed secrets use a 30-day recovery window and create-before-destroy, but
those safeguards do not populate externally managed values at a new path.

Mattermost Notifications
------------------------
Set ``comms_platform`` explicitly when a mission's application selects a
communications backend. PADRE uses ``slack``; HERMES keeps legacy auto-detection;
iMPAX and SWxSOC Pipeline use ``mattermost``. For Mattermost, also set
``enable_mattermost = true``. Both Lambdas receive
``COMMS_PLATFORM=mattermost`` and the configured ``MATTERMOST_URL``. Terraform
reads ``MATTERMOST_TOKEN`` and ``MATTERMOST_CHANNEL_ID`` from the mission and
environment-specific Mattermost secret, whose JSON value must contain:

.. code-block:: json

    {
      "token": "<Mattermost token>",
      "channel_id": "<Mattermost channel ID>"
    }

Create and tag that external secret before enabling Mattermost. At minimum use
``Mission=<mission>``, ``Service=communications``,
``Environment=Development|Production``, and ``ManagedBy=external``. The iMPAX
and ``swxsoc_pipeline`` configurations enable this for both their ``dev`` and
``prod`` workspaces; workspace-derived paths keep mission and environment
credentials separate.

The mission-first Mattermost secrets for iMPAX and SWxSOC Pipeline
(``swxsoc/<dev|prod>/impax/communications/mattermost`` and
``swxsoc/<dev|prod>/swxsoc-pipeline/communications/mattermost``) do not exist
yet. Until all four are seeded and tagged through an approved migration, the
``dev-impax``, ``prod-impax``, ``dev-swxsoc_pipeline``, and
``prod-swxsoc_pipeline`` plans fail at the secret data source by design, and
the live Lambdas keep their current environment variables.

Because Lambda requires the token as an environment variable, Terraform reads
the secret value during the apply and records it as sensitive data in the
encrypted remote state. Restrict access to the Terraform state bucket and its
KMS key accordingly.
