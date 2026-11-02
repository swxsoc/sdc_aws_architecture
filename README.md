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
  - Mission-specific configurations (`hermes.tfvars`, `padre.tfvars`, `impax.tfvars`, `gdctb.tfvars`, `demo.tfvars`)
  - Lambda functions for artifacts, processing, and sorting
  - Pipeline-specific infrastructure
  - New general pipeline config: `swxsoc_pipeline.tfvars` (REACH as the first instrument, mission name `swxsoc_pipeline`)

### Deployment Infrastructure
- Managed in `deployment-infrastructure-terraform/`
- Uses a dedicated S3 state key and the default workspace
- Declaratively imports all 33 live CodeBuild projects and adds one dedicated
  base-architecture project, the six GDC Trailblazer (gdctb) projects, and the
  five demo mission projects, and the demo smoke test, for 48 managed projects
  in total
- Owns their predictable service roles, policies, webhooks, log groups, and tags
- Generates a mission's standard projects from one entry in `local.missions`
- Manages the eleven dependency rebuild triggers, the PADRE reprocessing job,
  and the demo smoke test as least-privilege support projects with generated
  buildspecs

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

### gdctb Notes
- `gdctb.tfvars` is the GDC Trailblazer mission: `mission_name = "gdctb"`,
  `instrument_names = ["craft", "cape-eea"]` (craft first, by convention), and
  the four Lambda components including concating, matching the fan-out in the
  GDC-Trailblazer base image buildspec.
- Nothing exists in AWS for gdctb yet. Create the `dev-gdctb` and `prod-gdctb`
  workspaces, seed and tag the external
  `swxsoc/<dev|prod>/gdctb/communications/mattermost` secret, then apply with
  every `enable_*_lambda` flag false so the buckets, topics, queues, ECR
  repositories, and database are created before any image exists.
- Apply the deployment root to create the gdctb CodeBuild projects, run
  `build_gdctb_sdc_aws_base_docker_image`, and once each Lambda image has been
  pushed set its `enable_*_lambda` flag to true. Keep
  `adopt_existing_lambda_log_groups = false` through those applies, which
  create the log groups; remove it only after every Lambda log group exists in
  both workspaces, or the plan fails importing a group that is not there.
- Set `enable_grafana_secret = true` once
  `swxsoc/<dev|prod>/gdctb/processing/grafana` holds the API key for the
  GDCTB Grafana instance (http://grafana.gdctb.swsoc.smce.nasa.gov/), which is
  deployed from the `sdc_aws_grafana` repository alongside the other missions.

### demo Notes

`demo.tfvars` is the lightweight end-to-end test mission. It runs the same
base-image, Lambda-image, and architecture builds as a live mission, so it is
the place to try a pipeline change, measure what one mission workspace costs,
and develop features without touching a live dev or prod pipeline.

- Shape: `mission_name = "demo"`, `instrument_names = ["craft", "myinst"]`,
  processing, sorting, and artifacts only (`needs_concating = false`), no
  Grafana secret, Mattermost notifications, 14-day Lambda log retention, and
  7-day expiry of noncurrent object versions. The only external secret the
  plan reads is the Mattermost one below.
- Notifications: Sorting and Artifacts post to a demo Mattermost channel.
  Create the channel and a bot token, then seed and tag
  `swxsoc/dev/demo/communications/mattermost` (`token` and `channel_id` keys;
  tags `Mission=demo`, `Service=communications`, `Environment=Development`,
  `ManagedBy=external`) as described under Mattermost below, before the first
  `dev-demo` plan. One secret serves one workspace, so demo needs one channel
  while it is `dev-demo` only.
- Only the `dev-demo` workspace is intended to exist; do not create
  `prod-demo`. The deployment root lists `demo` as a development-only mission,
  so release tags never start a production demo build: demo image projects
  have no release-tag webhook filter (the Lambda repositories are shared, so a
  live mission's tag would otherwise reach them), and `trigger_rebuild_swxsoc`
  rebuilds the demo base image for `DEVELOPMENT` on a swxsoc release tag.
- The `demo` mission already exists in the swxsoc package's default
  configuration and is selected inside the Lambdas by `SWXSOC_MISSION=demo`,
  but as shipped it cannot route or process a file. Its instruments are
  `MyInstrument1` and `MyInstrument2`: the package derives bucket names from
  each instrument's `name`, so those are not even legal bucket names, there
  is no `craft`, there are two science instruments against Terraform's one,
  and its data levels have no `raw`. Its `instrument_package` points at
  `demo_myinst1`, which exists nowhere, and the processing Lambda re-raises a
  failed import, so every sorted file would error and be retried. The
  package's demo entry therefore needs instruments `craft`
  (`instrument_package: demo_craft`) and `myinst` (lowercase, matching the
  `dev-demo-craft` and `dev-demo-myinst` buckets), a `raw` level, and an
  instrument package per instrument. `swxsoc/demo_craft` (tag `v0.0.1`,
  generated from `swxsoc/instrument_pkg_template`) is the first: its
  `process_file` turns one l0 CSV into one l1 CSV and stops, with no CDF
  library. Until a `myinst` package exists only craft files process end to
  end, and the smoke test uses craft.
- Bootstrap order, the same as gdctb:
  1. Make the companion changes in other repositories, in this order.
     First, and before the deployment root is applied in step 3: demo has no
     base image repository, so `build_demo_sdc_aws_base_docker_image` builds
     `swxsoc/swxsoc_pipeline_sdc_aws_base_docker_image` with
     `MISSION_NAME=demo`, and that buildspec must derive the image name
     (`demo-swsoc-docker-lambda-base`) and the `build_demo_*` Lambda projects
     it starts from `MISSION_NAME`, keeping `swxsoc_pipeline` as the default
     (the Lambda image buildspecs already derive their names that way). This
     is a hard gate, not a nicety: until that change is merged the demo base
     project ignores `MISSION_NAME`, publishes to the live
     `dev-swxsoc-pipeline-docker-lambda-base` repository, and starts the three
     `build_swxsoc_pipeline_*` Lambda builds, redeploying `dev-swxsoc_pipeline`;
     once the deployment root is applied, the demo project's webhook does that
     on the next push to that repository's `main`. Second, add
     `lambda_function/demo-requirements.txt` to
     `swxsoc/sdc_aws_processing_lambda` listing `swxsoc`, `swxsoc[tracker]`,
     `psycopg2-binary`, and
     `demo_craft @ git+https://github.com/swxsoc/demo_craft.git@v0.0.1`
     (the package exists; see the swxsoc bullet above); that buildspec selects
     `<mission>-requirements.txt` and exits if it is missing (the
     `swxsoc_pipeline-requirements.txt` there is the model; sorting and
     artifacts share one `requirements.txt` and need nothing). Third, change
     the swxsoc package's demo mission configuration as described above.
  2. Seed and tag the `swxsoc/dev/demo/communications/mattermost` secret,
     then create the `dev-demo` workspace and apply `demo.tfvars` with every
     `enable_*_lambda` flag false to create the buckets, topics, queues, ECR
     repositories, Timestream table, and database.
  3. Apply the deployment root to create the five `build_demo_*` CodeBuild
     projects, run `build_demo_sdc_aws_base_docker_image`, and once each
     Lambda image has been pushed set its `enable_*_lambda` flag to true.
     Keep `adopt_existing_lambda_log_groups = false`; those applies create the
     log groups.
- Smoke test: the deployment root's `demo-smoke-test` CodeBuild project runs
  `scripts/demo_smoke_test.py`, which uploads one synthetic
  `demo_craft_l0_<time>_v0.0.1.csv` to `dev-demo-swsoc-incoming` and verifies
  the sorted copy in `dev-demo-craft`, a processed output, the Timestream
  record, and the Mattermost post, then deletes what it created; any missing
  stage fails the build. Its daily schedule is created disabled
  (`enable_demo_smoke_test_schedule` in the deployment root); turn it on after
  step 3, once the processing image includes `demo_craft`, and start the project by
  hand from CodeBuild at any time. To check names and access first, run
  `python scripts/demo_smoke_test.py --dry-run` with credentials for the
  account; `--help` lists the options, including `--skip-rds` for a host the
  RDS security group does not admit.
- Baseline cost. Almost all of the idle cost is the RDS instance; everything
  else is pay-per-use and near zero when no files are flowing. Estimated from
  us-east-1 list prices for one dev workspace; confirm in Cost Explorer with
  the `Mission=demo` cost allocation tag.

  | Resource | Approximate monthly cost (USD) |
  | --- | --- |
  | RDS `db.t4g.micro`, single AZ | 12 |
  | RDS 30 GB gp2 storage | 3.50 |
  | KMS key for the RDS secret | 1 |
  | Secrets Manager (RDS secret and the external Mattermost secret) | 0.80 |
  | ECR private image storage (3 images) | about 0.50 |
  | S3, SNS, SQS, Timestream, CloudWatch Logs, Lambda at idle | under 1 |
  | Total at idle | about 19 |

  CodeBuild is billed per build minute on top of that, driven by pushes to
  the demo and Lambda repositories and by `trigger_rebuild_swxsoc`, which
  rebuilds the demo base image on every swxsoc package release. The daily
  smoke test adds a few build minutes a day, under 2 USD a month.

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
or `CONCATING` when `TAG` is supplied. `EXECUTOR` and `ALERT` are also
supported: they use the base Terraform root and its `default` workspace, and
the executor and alert image builds invoke the dedicated
`build_swxsoc_sdc_aws_base_architecture` project rather than a mission
architecture project.

Mission image deployments require an explicit `CDK_ENVIRONMENT` of
`DEVELOPMENT` or `PRODUCTION`; executor and alert deployments always use the
base `default` workspace and need no environment override. Image deployments
create a saved, targeted plan for only the triggering Lambda and refuse any
delete, replacement, or unrelated resource change before applying it. Direct
builds use CodeBuild source metadata to distinguish `main` and release-tag
builds; Git tags in the checked-out architecture commit are never used to
infer the environment of a downstream Lambda image build.

The build jobs pass immutable image tags into Terraform. For a manual pipeline
apply, pass an immutable `pf_image_tag`, `sf_image_tag`, `af_image_tag`, and/or
`cf_image_tag` for every enabled private-ECR Lambda. For a manual base apply,
pass an immutable `ef_image_tag` and `alert_image_tag`. Terraform rejects missing image selections
and the mutable `latest` tag before a Lambda can be changed. Always review the
plan, and never apply an unexpected delete or replacement.

The CodeBuild fleet is managed by `deployment-infrastructure-terraform/`.
Image projects use each repository's `buildspec.yml`, Docker privileged mode,
the current standard build image, their existing service role (adopted, with a
managed least-privilege policy added beside the legacy ones), and uniform
`Mission`, `Service`, `Environment=Shared`, `Purpose`, `Project`, and
`ManagedBy=terraform` tags. Architecture projects accept pull-request webhooks
for validation only; image builds invoke them explicitly for targeted deploys.
This prevents an architecture merge from applying unrelated infrastructure.
Every project writes to an explicit, tagged `/aws/codebuild/<project>` log
group with 90-day retention, and the base and pipeline roots give each managed
Lambda the same explicit 90-day log group. See
`deployment-infrastructure-terraform/README.md` for the full project list,
support-trigger behavior, and the first-apply import order.

The alert Lambda (`aws_sdc_alert_lambda_function`), its ECR repository,
execution role, EventBridge schedule, and log group are managed by the base
root. It keeps the legacy `gdc_test_kafka` GCN secret through the explicit
`alert_gcn_secret_name` override until a mission-first copy exists.

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
HERMES preserves legacy auto-detection, the existing iMPAX plus SWxSOC
Pipeline Mattermost environments are adopted through their mission-specific
external secrets, and GDCTB and demo select Mattermost from the start.

Changing an existing Secrets Manager name creates a replacement because AWS
does not support renaming secrets. Before applying a naming migration, copy any
externally managed secret value to the new path and update its consumers. Never
put credentials in tfvars or commit them to this repository.

The mission-first Mattermost secrets for iMPAX and SWxSOC Pipeline
(`swxsoc/<dev|prod>/impax/communications/mattermost` and
`swxsoc/<dev|prod>/swxsoc-pipeline/communications/mattermost`) do not exist
yet. Until all four are seeded and tagged through an approved migration, the
`dev-impax`, `prod-impax`, `dev-swxsoc_pipeline`, and `prod-swxsoc_pipeline`
plans fail at the secret data source by design; the live Lambdas keep their
current environment variables in the meantime. The new
`swxsoc/<dev|prod>/gdctb/communications/mattermost` secrets must exist before
the first `dev-gdctb` and `prod-gdctb` plans for the same reason.

The base tfvars intentionally pins `grafana-credentials`, `udl-credentials`,
and `gdc_test_kafka` during the migration, and `hermes.tfvars` and
`padre.tfvars` pin `grafana-credentials` for the same reason. Remove each override only after its value-bearing
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
