# SDC AWS Pipeline Architecture

This repository contains Terraform configurations for managing AWS infrastructure across multiple missions, with separate environments for development and production.

## Repository Structure

```
.
├── base-infrastructure-terraform/    # Base shared infrastructure
└── pipeline-infrastructure-terraform/  # Mission-specific pipeline infrastructure
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
  - New general pipeline config: `swxsoc.tfvars` (REACH as the first instrument)

## Getting Started

1. Install prerequisites:
   - Terraform
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
terraform workspace select <environment>-<mission>
terraform init
terraform plan -var-file=<mission>.tfvars
terraform apply -var-file=<mission>.tfvars
```

### swxsoc Notes
- `swxsoc.tfvars` uses mission-scoped names and starts with `instrument_names = ["reach"]`.
- First apply uses public Lambda base images via `*_image_uri_override` so the deploy succeeds before mission images are pushed to ECR. Replace these overrides with real ECR image URIs later.
- Grafana credentials are optional for `swxsoc` (`enable_grafana_secret = false` by default). Enable it only after the secret exists.
- Lambda VPC subnets and RDS ingress allowlists are configurable via tfvars to avoid hard-coded IDs when needed.

## Documentation

Comprehensive documentation is available in the `docs/` directory:
- Development Guide: `docs/dev-guide/`
- User Guide: `docs/user-guide/`
- Pipeline Diagrams: `docs/images/`

## License

See [LICENSE](LICENSE) file for details.
