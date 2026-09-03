# CodeBuild deployment infrastructure

This Terraform root owns the shared image-build, architecture-deployment, and
support CodeBuild fleet. It has a dedicated S3 backend key, uses native S3
lockfiles, and does not share state with either mission infrastructure root.

## Managed projects (34)

The live account had 33 CodeBuild projects; this root adopts every one of them
and adds one new project, for 34 managed projects.

| Group | Projects | Count |
| --- | --- | --- |
| Mission base images | `build_<mission>_sdc_aws_base_docker_image` for hermes, impax, padre, swxsoc_pipeline | 4 |
| Mission architecture | `build_<mission>_sdc_aws_pipeline_architecture` for the same four missions | 4 |
| Mission Lambda images | processing, sorting, and artifact projects for every mission, plus PADRE concating | 13 |
| Executor image | `build_aws_sdc_executor_lambda_function` | 1 |
| Alert image | `build_aws_sdc_alert_lambda_function` | 1 |
| Base architecture (new) | `build_swxsoc_sdc_aws_base_architecture` | 1 |
| Dependency rebuild triggers | `trigger_rebuild_hermes_{core,eea,merit,nemisis,spani}`, `trigger_rebuild_padre_{craft,meddea,sharp}`, `trigger_rebuild_swxsoc` | 9 |
| Reprocessing | `padre-reprocessing-requests` | 1 |

`aws_codebuild_project.pipeline` holds the 24 image and architecture projects
and `aws_codebuild_project.support` holds the 10 support projects. Every
project gets a predictable Terraform-managed role and policy, an explicit
`/aws/codebuild/<project>` log group with 90-day retention, and the uniform
`Mission`, `Service`, `Environment=Shared`, `Purpose`, `Project`, and
`ManagedBy=terraform` tags.

### Base architecture handoff

`build_swxsoc_sdc_aws_base_architecture` is the only project that applies the
base root. The executor and alert image builds start it with
`LAMBDA_PIPELINE=EXECUTOR` or `LAMBDA_PIPELINE=ALERT` and the immutable `TAG`.
It has no webhook: pull-request validation of this repository already runs
through the mission architecture projects, and the base root must never be
applied from an unreviewed branch. Before this root is applied, the executor
and alert repositories still point at their previous handoff target, so merge
their buildspec pull requests only after this project exists.

### Support projects

The nine `trigger_rebuild_*` projects watch a dependency repository and start
the declared mission base-image builds. Their generated buildspec
(`buildspecs/dependency-trigger.yml.tftpl`) classifies the source and maps it
to an environment:

- a release tag rebuilds with `CDK_ENVIRONMENT=PRODUCTION`;
- a push to `main` rebuilds with `CDK_ENVIRONMENT=DEVELOPMENT`;
- a manual start honors an explicit `CDK_ENVIRONMENT` and rejects anything
  other than `DEVELOPMENT`/`PRODUCTION`;
- any other branch or pull request exits without starting downstream builds.

`trigger_rebuild_swxsoc` fans out to all four mission base images; each
mission trigger only rebuilds its own base image. The role for each trigger is
scoped to `codebuild:StartBuild` on exactly its declared targets.

`padre-reprocessing-requests` runs `buildspecs/reprocessing.yml.tftpl`, which
prints the build banner and then processes newly added `requests/*.json` files
(excluding `requests/submit/`). Its role can invoke Lambda functions and read
mission S3 objects, and nothing else.

Neither support template writes secret values to the log.

## First apply and import order

Everything is adopted through declarative `import` blocks in `imports.tf`
while `adopt_existing_codebuild_projects=true` (the default):

1. 33 existing projects (`pipeline` and `support`);
2. the 11 existing image webhooks, 3 existing architecture webhooks, 4 existing
   dependency-trigger webhooks, and the reprocessing webhook;
3. the 28 `/aws/codebuild/<project>` log groups that already exist. The six
   remaining groups are created: the iMPAX architecture project, the new base
   architecture project, and the four `trigger_rebuild_hermes_*` projects that
   have never run.

Creates in the same plan are the new base architecture project, every
Terraform-managed role and policy, and the webhooks that do not exist yet.
In-place updates switch each project from its stale inline buildspec to
`buildspec.yml` on `main`, enable Docker privileged mode for image builds,
attach the new roles, and apply tags and retention. A correct plan contains no
deletes and no replacements; do not apply one that does.

```bash
terraform init
terraform plan -out=codebuild.tfplan
terraform show codebuild.tfplan
terraform apply codebuild.tfplan
```

Do not apply this root until the associated base-image, Lambda-image, and
architecture buildspec pull requests are merged. Applying is a manual,
reviewed step; nothing in this repository or its CI applies this root
automatically.

After the first successful apply, leave
`adopt_existing_codebuild_projects=true`; Terraform records the imports in
state and future plans are ordinary drift checks.

## Add a mission

Add one entry to `local.missions` in `codebuild.tf` with:

- the mission key used by its Terraform workspaces and project names;
- the mission base-image repository URL;
- the CodeConnection ARN, or an empty string for an existing account-level
  GitHub OAuth credential;
- the enabled Lambda components.

Terraform generates the base-image, architecture, and component projects along
with one tagged service role, policy, and log group per project. New projects
do not need entries in the import sets because they do not exist yet. Add a
`local.dependency_trigger_projects` entry for each dependency repository that
should rebuild the mission base image.

Image projects build on `main`, release tags, and pull requests. The repository
buildspec skips deployment for pull requests. Architecture projects accept
pull-request validation webhooks only; image projects invoke them explicitly
with the mission, environment, component, and immutable image tag.
