# SDC AWS Pipeline Architecture

This repository contains Terraform configurations for managing AWS infrastructure and image deployment pipelines across multiple missions, with separate environments for development and production.

## Repository Structure

```
.
├── base-infrastructure-terraform/        # Base shared infrastructure
├── pipeline-infrastructure-terraform/    # Mission-specific pipeline infrastructure
└── deployment-infrastructure-terraform/  # Shared CodeBuild deployment fleet
```

## Infrastructure Management

### Base Infrastructure
- Managed in `base-infrastructure-terraform/`
- Uses default Terraform workspace
- Contains shared resources used across all pipelines
- Key components:
  - Base AWS infrastructure setup
  - Executor Lambda function
  - Common configuration in `swxsoc.auto.tfvars`

### Pipeline Infrastructure
- Managed in `pipeline-infrastructure-terraform/`
- Uses separate workspaces for each mission's environments
- Two workspaces per mission: development (dev) and production (prod)
- Components:
  - Mission-specific configurations (`hermes.tfvars`, `padre.tfvars`)
  - Lambda functions for artifacts, processing, and sorting
  - Pipeline-specific infrastructure
  - New general pipeline config: `swxsoc_pipeline.tfvars` (REACH as the first instrument, mission name `swxsoc_pipeline`)

### Deployment Infrastructure
- Managed in `deployment-infrastructure-terraform/`
- Uses a dedicated S3 state key and the default workspace
- Declaratively imports the 22 existing CodeBuild projects
- Owns their predictable service roles, policies, webhooks, and tags
- Generates a mission's standard projects from one entry in `local.missions`

## Getting Started

1. Install prerequisites:
   - Terraform 1.14.x
   - AWS CLI configured with appropriate credentials

2. Base Infrastructure Deployment:
```bash
cd base-infrastructure-terraform
terraform init
terraform plan
terraform apply
```

3. Pipeline Infrastructure Deployment:
```bash
cd pipeline-infrastructure-terraform
terraform init
terraform workspace select <environment>-<mission>
terraform plan -var-file=<mission>.tfvars
terraform apply -var-file=<mission>.tfvars
```

### swxsoc_pipeline Notes
- `swxsoc_pipeline.tfvars` uses mission-scoped names and starts with `instrument_names = ["reach"]` and `mission_name = "swxsoc_pipeline"`.
- Lambda creation is gated by `enable_*_lambda` flags so the first apply can succeed before images are pushed. Set these to `true` after the ECR images exist.
- Grafana credentials are optional for `swxsoc_pipeline` (`enable_grafana_secret = false` by default). Enable it only after the secret exists.
- Lambda VPC subnets and RDS ingress allowlists are configurable via tfvars to avoid hard-coded IDs when needed.

### Lambda image deployments

Lambda image build projects trigger this repository's CodeBuild project after
pushing an immutable image tag. The downstream build accepts either `MISSION`
or the legacy `MISSION_NAME`, selects the matching `dev-<mission>` or
`prod-<mission>` Terraform workspace, and applies the triggering component's
image tag. `LAMBDA_PIPELINE` must be one of `PROCESSING`, `SORTING`, `ARTIFACTS`,
or `CONCATING` when `TAG` is supplied. `EXECUTOR` is also supported: it uses
the base Terraform root and its `default` workspace.

Mission image deployments require an explicit `CDK_ENVIRONMENT` of
`DEVELOPMENT` or `PRODUCTION`; executor deployments always use the base
`default` workspace and need no environment override. Image deployments
create a saved, targeted plan for only the triggering Lambda and refuse any
delete, replacement, or unrelated resource change before applying it. Direct
builds use CodeBuild source metadata to distinguish `main` and release-tag
builds; Git tags in the checked-out architecture commit are never used to
infer the environment of a downstream Lambda image build.

The build jobs pass immutable image tags into Terraform. For a manual pipeline
apply, pass an immutable `pf_image_tag`, `sf_image_tag`, `af_image_tag`, and/or
`cf_image_tag` for every enabled private-ECR Lambda. For a manual base apply,
pass an immutable `ef_image_tag`. Terraform rejects missing image selections
and the mutable `latest` tag before a Lambda can be changed. Always review the
plan, and never apply an unexpected delete or replacement.

The CodeBuild fleet is managed by `deployment-infrastructure-terraform/`.
Image projects use each repository's `buildspec.yml`, Docker privileged mode,
the current standard build image, a predictable Terraform-managed role, and
uniform `Mission`, `Service`, `Environment=Shared`, `Purpose`, `Project`, and
`ManagedBy=terraform` tags. Architecture projects accept pull-request webhooks
for validation only; image builds invoke them explicitly for targeted deploys.
This prevents an architecture merge from applying unrelated infrastructure.

All three S3 backends use native lockfiles. Terraform execution roles need
access to both the state object and its `.tflock` object.

### Resource tags

The base and pipeline roots enforce `Mission`, `Service`, `Environment`,
`Purpose`, `Project`, and `ManagedBy=terraform` through AWS provider default
tags. The deployment root applies the same complete map to every taggable
CodeBuild and IAM resource. Shared pipeline resources use
`Service=sdc-aws-pipeline`; component resources override that with `executor`,
`processing`, `sorting`, `artifacts`, `concating`, `container-base`, or
`terraform-deployment` as appropriate.

### Secrets Manager names

Secrets use a mission-first hierarchy:

```text
swxsoc/<environment>/<mission>/<service>/<secret>
```

Paths are lowercase; mission underscores are normalized to hyphens. Examples
include `swxsoc/prod/hermes/processing/rds` and
`swxsoc/dev/swxsoc/executor/udl`. Credentials shared by multiple Lambda
services use a purpose-specific service path, such as
`swxsoc/dev/swxsoc-pipeline/communications/mattermost`. Terraform applies
the same `Mission`, `Service`, and `Environment` tags to managed secrets.

Communications platforms are explicit per mission: PADRE selects Slack,
HERMES preserves legacy auto-detection, and the existing iMPAX plus SWxSOC
Pipeline Mattermost environments are adopted through their mission-specific
external secrets.

Changing an existing Secrets Manager name creates a replacement because AWS
does not support renaming secrets. Before applying a naming migration, copy any
externally managed secret value to the new path and update its consumers. Never
put credentials in tfvars or commit them to this repository.

The base tfvars intentionally pins `grafana-credentials` and `udl-credentials`
during the migration. Remove each override only after its value-bearing
mission-first target exists and the Grafana Terraform state move has been
planned. This keeps executor image deployments working during the transition.

Pipeline deployments must use an explicit `dev-<mission>` or `prod-<mission>`
workspace. Terraform refuses to plan the pipeline root in `default`, which is
reserved for base infrastructure because the two roots currently share a
backend key. RDS instances use the deterministic identifier
`<environment>-<mission>-cdftracker-db`; review the first migration plan before
applying it to an existing database.

### Adding a mission

1. Copy an existing mission tfvars file and set its unique buckets,
   instruments, feature flags, and mission name.
2. Add one entry to `deployment-infrastructure-terraform/codebuild.tf` under
   `local.missions`, selecting the base-image repository, source connection,
   and enabled Lambda components.
3. Create `dev-<mission>` and `prod-<mission>` workspaces, seed external secrets
   at the mission-first paths, and plan each workspace before applying.
4. Merge the mission's base/Lambda repository support before applying the
   generated CodeBuild project changes.

## Documentation

Comprehensive documentation is available in the `docs/` directory:
- Development Guide: `docs/dev-guide/`
- User Guide: `docs/user-guide/`
- Pipeline Diagrams: `docs/images/`

## License

See [LICENSE](LICENSE) file for details.
