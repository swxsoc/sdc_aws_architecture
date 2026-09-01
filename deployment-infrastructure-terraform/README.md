# CodeBuild deployment infrastructure

This Terraform root owns the shared image-build and architecture-deployment
fleet. It has a dedicated S3 backend key, uses native S3 lockfiles, and does not
share state with either mission infrastructure root.

The first apply adopts the existing projects and webhooks through `imports.tf`.
At the audited 2026-09-01 baseline, a normal plan contains 36 imports, 52
creates, 36 in-place updates, and no deletes or replacements. Counts can change
as the fleet evolves; always inspect a fresh saved plan instead of relying on
that baseline.

Do not apply this root until the associated base-image, Lambda-image, and
architecture buildspec pull requests are merged. The project update switches
every build from its stale inline buildspec to `buildspec.yml` on `main`.

```bash
terraform init
terraform plan -out=codebuild.tfplan
terraform show codebuild.tfplan
terraform apply codebuild.tfplan
```

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
with one tagged service role and policy per project. New projects do not need
entries in the import sets because they do not exist yet.

Image projects build on `main`, release tags, and pull requests. The repository
buildspec skips deployment for pull requests. Architecture projects accept
pull-request validation webhooks only; image projects invoke them explicitly
with the mission, environment, component, and immutable image tag.
