locals {
  # Adding a mission is deliberately data-driven: add one entry with its base
  # image repository, source connection, and enabled Lambda components. The
  # standard project, role, policy, webhook, and tags are generated below.
  missions = {
    hermes = {
      base_repository_url = "https://github.com/HERMES-SOC/sdc_aws_base_docker_image.git"
      connection_arn      = var.hermes_codeconnection_arn
      lambda_components   = toset(["processing", "sorting", "artifacts"])
    }
    impax = {
      base_repository_url = "https://github.com/iMPAXSat/sdc_aws_base_docker_image"
      connection_arn      = ""
      lambda_components   = toset(["processing", "sorting", "artifacts"])
    }
    padre = {
      base_repository_url = "https://github.com/PADRESat/sdc_aws_base_docker_image.git"
      connection_arn      = var.shared_codeconnection_arn
      lambda_components   = toset(["processing", "sorting", "artifacts", "concating"])
    }
    swxsoc_pipeline = {
      base_repository_url = "https://github.com/swxsoc/swxsoc_pipeline_sdc_aws_base_docker_image"
      connection_arn      = var.shared_codeconnection_arn
      lambda_components   = toset(["processing", "sorting", "artifacts"])
    }
  }

  lambda_components = {
    processing = {
      project_suffix = "processing_lambda"
      repository_url = "https://github.com/swxsoc/sdc_aws_processing_lambda"
    }
    sorting = {
      project_suffix = "sorting_lambda"
      repository_url = "https://github.com/swxsoc/sdc_aws_sorting_lambda"
    }
    artifacts = {
      # The live project name is intentionally singular even though the
      # repository and Terraform component are plural.
      project_suffix = "artifact_lambda"
      repository_url = "https://github.com/swxsoc/sdc_aws_artifacts_lambda"
    }
    concating = {
      project_suffix = "concating_lambda"
      repository_url = "https://github.com/swxsoc/sdc_aws_concating_lambda"
    }
  }

  mission_lambda_projects = {
    for pair in flatten([
      for mission_name, mission in local.missions : [
        for component_name in mission.lambda_components : {
          name           = "build_${mission_name}_sdc_aws_${local.lambda_components[component_name].project_suffix}"
          mission        = mission_name
          service        = component_name
          kind           = "image"
          repository_url = local.lambda_components[component_name].repository_url
          connection_arn = mission.connection_arn
        }
      ]
    ]) : pair.name => pair
  }

  mission_base_projects = {
    for mission_name, mission in local.missions :
    "build_${mission_name}_sdc_aws_base_docker_image" => {
      name           = "build_${mission_name}_sdc_aws_base_docker_image"
      mission        = mission_name
      service        = "container-base"
      kind           = "image"
      repository_url = mission.base_repository_url
      connection_arn = mission.connection_arn
    }
  }

  mission_architecture_projects = {
    for mission_name, mission in local.missions :
    "build_${mission_name}_sdc_aws_pipeline_architecture" => {
      name           = "build_${mission_name}_sdc_aws_pipeline_architecture"
      mission        = mission_name
      service        = "terraform-deployment"
      kind           = "architecture"
      repository_url = "https://github.com/swxsoc/sdc_aws_architecture"
      connection_arn = mission.connection_arn
    }
  }

  executor_project = {
    build_aws_sdc_executor_lambda_function = {
      name           = "build_aws_sdc_executor_lambda_function"
      mission        = "swxsoc"
      service        = "executor"
      kind           = "image"
      repository_url = "https://github.com/swxsoc/sdc_aws_executor_lambda"
      connection_arn = var.shared_codeconnection_arn
    }
  }

  codebuild_projects = merge(
    local.mission_base_projects,
    local.mission_architecture_projects,
    local.mission_lambda_projects,
    local.executor_project,
  )

  image_projects = {
    for project_name, project in local.codebuild_projects :
    project_name => project if project.kind == "image"
  }

  architecture_projects = {
    for project_name, project in local.codebuild_projects :
    project_name => project if project.kind == "architecture"
  }

  role_name_by_project = {
    for project_name, project in local.codebuild_projects :
    project_name => substr("swxsoc-codebuild-${replace(project.mission, "_", "-")}-${project.service}", 0, 64)
  }

  existing_image_webhooks = toset([
    "build_aws_sdc_executor_lambda_function",
    "build_hermes_sdc_aws_base_docker_image",
    "build_impax_sdc_aws_base_docker_image",
    "build_padre_sdc_aws_artifact_lambda",
    "build_padre_sdc_aws_base_docker_image",
    "build_padre_sdc_aws_concating_lambda",
    "build_padre_sdc_aws_processing_lambda",
    "build_padre_sdc_aws_sorting_lambda",
    "build_swxsoc_pipeline_sdc_aws_base_docker_image",
    "build_swxsoc_pipeline_sdc_aws_processing_lambda",
    "build_swxsoc_pipeline_sdc_aws_sorting_lambda",
  ])

  existing_architecture_webhooks = toset([
    "build_hermes_sdc_aws_pipeline_architecture",
    "build_padre_sdc_aws_pipeline_architecture",
    "build_swxsoc_pipeline_sdc_aws_pipeline_architecture",
  ])
}

resource "aws_iam_role" "codebuild" {
  for_each = local.codebuild_projects

  name = local.role_name_by_project[each.key]
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })

  tags = {
    Environment = "Shared"
    ManagedBy   = "terraform"
    Mission     = each.value.mission
    Project     = each.value.mission
    Purpose     = "Lambda image deployment"
    Service     = each.value.service
  }
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = local.codebuild_projects

  name = "${local.role_name_by_project[each.key]}-policy"
  role = aws_iam_role.codebuild[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "BuildLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = [
            "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${each.key}",
            "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${each.key}:*",
          ]
        },
      ],
      each.value.connection_arn != "" ? [
        {
          Sid    = "RepositoryConnection"
          Effect = "Allow"
          Action = [
            "codeconnections:UseConnection",
            "codestar-connections:UseConnection",
          ]
          Resource = each.value.connection_arn
        },
      ] : [],
      each.value.kind == "image" ? [
        {
          Sid    = "ContainerRegistry"
          Effect = "Allow"
          Action = [
            "ecr:*",
            "ecr-public:*",
            "sts:GetServiceBearerToken",
          ]
          Resource = "*"
        },
        {
          Sid      = "StartDownstreamBuilds"
          Effect   = "Allow"
          Action   = ["codebuild:StartBuild"]
          Resource = "arn:${data.aws_partition.current.partition}:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/build_*"
        },
        ] : [
        {
          Sid    = "TerraformManagedServices"
          Effect = "Allow"
          Action = [
            "application-autoscaling:*",
            "cloudwatch:*",
            "ec2:*",
            "ecr:*",
            "ecr-public:*",
            "events:*",
            "iam:*",
            "kms:*",
            "lambda:*",
            "logs:*",
            "rds:*",
            "s3:*",
            "secretsmanager:*",
            "sns:*",
            "sqs:*",
            "ssm:*",
            "sts:GetCallerIdentity",
            "sts:GetServiceBearerToken",
            "tag:GetResources",
            "tag:GetTagKeys",
            "tag:GetTagValues",
            "timestream:*",
          ]
          Resource = "*"
        },
      ],
    )
  })
}

resource "aws_codebuild_project" "pipeline" {
  for_each = local.codebuild_projects

  name                   = each.key
  description            = "${each.value.mission} ${each.value.service} build and deployment"
  service_role           = aws_iam_role.codebuild[each.key].arn
  build_timeout          = 60
  queued_timeout         = 480
  source_version         = "main"
  concurrent_build_limit = 1

  artifacts {
    type = "NO_ARTIFACTS"
  }

  cache {
    type = "NO_CACHE"
  }

  environment {
    compute_type                = each.value.kind == "image" ? "BUILD_GENERAL1_MEDIUM" : "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = each.value.kind == "image"
    type                        = "LINUX_CONTAINER"

    environment_variable {
      name  = "MISSION_NAME"
      type  = "PLAINTEXT"
      value = each.value.mission
    }
  }

  logs_config {
    cloudwatch_logs {
      status      = "ENABLED"
      group_name  = "/aws/codebuild/${each.key}"
      stream_name = "build"
    }
  }

  source {
    type                = "GITHUB"
    location            = each.value.repository_url
    buildspec           = "buildspec.yml"
    git_clone_depth     = 1
    report_build_status = true

    dynamic "auth" {
      for_each = each.value.connection_arn == "" ? [] : [each.value.connection_arn]
      content {
        type     = "CODECONNECTIONS"
        resource = auth.value
      }
    }
  }

  tags = {
    Environment = "Shared"
    ManagedBy   = "terraform"
    Mission     = each.value.mission
    Project     = each.value.mission
    Purpose     = "Lambda image deployment"
    Service     = each.value.service
  }
}

# Image repositories build on main and release tags. Pull requests also run the
# guarded buildspec for a CodeBuild status, but the buildspec refuses deployment.
resource "aws_codebuild_webhook" "image" {
  for_each = local.image_projects

  project_name = aws_codebuild_project.pipeline[each.key].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/main$"
    }
  }

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/tags/.+"
    }
  }

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED, PULL_REQUEST_UPDATED, PULL_REQUEST_REOPENED"
    }
    filter {
      type    = "BASE_REF"
      pattern = "^refs/heads/main$"
    }
  }
}

# Architecture projects are invoked by image builds. Their webhooks validate
# pull requests only, preventing a merge from applying unrelated infrastructure.
resource "aws_codebuild_webhook" "architecture" {
  for_each = local.architecture_projects

  project_name = aws_codebuild_project.pipeline[each.key].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED, PULL_REQUEST_UPDATED, PULL_REQUEST_REOPENED"
    }
    filter {
      type    = "BASE_REF"
      pattern = "^refs/heads/main$"
    }
  }
}
