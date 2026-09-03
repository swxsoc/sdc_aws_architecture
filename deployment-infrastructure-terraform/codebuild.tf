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

  # Architecture projects clone this repository, which lives in the swxsoc
  # GitHub organization, so they use the shared SWxSOC connection regardless of
  # the mission's own connection. A mission with no connection keeps the
  # account-level OAuth credential.
  mission_architecture_projects = {
    for mission_name, mission in local.missions :
    "build_${mission_name}_sdc_aws_pipeline_architecture" => {
      name           = "build_${mission_name}_sdc_aws_pipeline_architecture"
      mission        = mission_name
      service        = "terraform-deployment"
      kind           = "architecture"
      repository_url = "https://github.com/swxsoc/sdc_aws_architecture"
      connection_arn = mission.connection_arn == "" ? "" : var.shared_codeconnection_arn
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

  alert_project = {
    build_aws_sdc_alert_lambda_function = {
      name           = "build_aws_sdc_alert_lambda_function"
      mission        = "swxsoc"
      service        = "alert"
      kind           = "image"
      repository_url = "https://github.com/swxsoc/sdc_aws_alert_lambda"
      connection_arn = var.shared_codeconnection_arn
    }
  }

  base_architecture_project = {
    build_swxsoc_sdc_aws_base_architecture = {
      name           = "build_swxsoc_sdc_aws_base_architecture"
      mission        = "swxsoc"
      service        = "terraform-deployment"
      kind           = "base-architecture"
      repository_url = "https://github.com/swxsoc/sdc_aws_architecture"
      connection_arn = var.shared_codeconnection_arn
    }
  }

  codebuild_projects = merge(
    local.mission_base_projects,
    local.mission_architecture_projects,
    local.mission_lambda_projects,
    local.executor_project,
    local.alert_project,
    local.base_architecture_project,
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

  # Projects declared here do not exist in the account yet, so the adoption
  # imports skip them and the first apply creates them.
  new_codebuild_projects = toset([
    "build_swxsoc_sdc_aws_base_architecture",
  ])

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

  dependency_trigger_projects = {
    trigger_rebuild_hermes_core = {
      mission        = "hermes"
      repository_url = "https://github.com/HERMES-SOC/hermes_core"
      connection_arn = var.hermes_codeconnection_arn
      targets        = ["build_hermes_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_hermes_eea = {
      mission        = "hermes"
      repository_url = "https://github.com/HERMES-SOC/hermes_eea"
      connection_arn = var.hermes_codeconnection_arn
      targets        = ["build_hermes_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_hermes_merit = {
      mission        = "hermes"
      repository_url = "https://github.com/HERMES-SOC/hermes_merit"
      connection_arn = var.hermes_codeconnection_arn
      targets        = ["build_hermes_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_hermes_nemisis = {
      mission        = "hermes"
      repository_url = "https://github.com/HERMES-SOC/hermes_nemisis"
      connection_arn = var.hermes_codeconnection_arn
      targets        = ["build_hermes_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_hermes_spani = {
      mission        = "hermes"
      repository_url = "https://github.com/HERMES-SOC/hermes_spani"
      connection_arn = var.hermes_codeconnection_arn
      targets        = ["build_hermes_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_padre_craft = {
      mission        = "padre"
      repository_url = "https://github.com/PADRESat/padre_craft"
      connection_arn = var.padre_codeconnection_arn
      targets        = ["build_padre_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_padre_meddea = {
      mission        = "padre"
      repository_url = "https://github.com/PADRESat/padre_meddea"
      connection_arn = var.padre_codeconnection_arn
      targets        = ["build_padre_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_padre_sharp = {
      mission        = "padre"
      repository_url = "https://github.com/PADRESat/padre_sharp"
      connection_arn = var.padre_codeconnection_arn
      targets        = ["build_padre_sdc_aws_base_docker_image"]
    }
    trigger_rebuild_swxsoc = {
      mission        = "swxsoc"
      repository_url = "https://github.com/swxsoc/swxsoc"
      connection_arn = var.shared_codeconnection_arn
      targets = [
        "build_hermes_sdc_aws_base_docker_image",
        "build_impax_sdc_aws_base_docker_image",
        "build_padre_sdc_aws_base_docker_image",
        "build_swxsoc_pipeline_sdc_aws_base_docker_image",
      ]
    }
  }

  dependency_trigger_buildspecs = {
    for project_name, project in local.dependency_trigger_projects :
    project_name => templatefile("${path.module}/buildspecs/dependency-trigger.yml.tftpl", {
      mission = project.mission
      targets = join("\n", [for target in project.targets : <<-EOT
        echo "Starting ${target} for $CDK_ENVIRONMENT..."
        aws codebuild start-build \
          --project-name "${target}" \
          --source-version main \
          --environment-variables-override \
            name=CDK_ENVIRONMENT,value="$CDK_ENVIRONMENT",type=PLAINTEXT
      EOT
      ])
    })
  }

  support_projects = merge(
    {
      for project_name, project in local.dependency_trigger_projects :
      project_name => merge(project, {
        name                  = project_name
        service               = "dependency-rebuild"
        kind                  = "dependency-trigger"
        purpose               = "Dependency-triggered image rebuild"
        buildspec             = local.dependency_trigger_buildspecs[project_name]
        compute_type          = "BUILD_GENERAL1_SMALL"
        git_clone_depth       = 1
        environment_variables = {}
      })
    },
    {
      padre-reprocessing-requests = {
        name           = "padre-reprocessing-requests"
        mission        = "padre"
        service        = "reprocessing"
        kind           = "reprocessing"
        purpose        = "Mission reprocessing requests"
        repository_url = "https://github.com/PADRESat/sdc_aws_reprocessing_requests"
        connection_arn = var.padre_codeconnection_arn
        buildspec = templatefile("${path.module}/buildspecs/reprocessing.yml.tftpl", {
          mission = "padre"
        })
        compute_type    = "BUILD_GENERAL1_SMALL"
        git_clone_depth = 5
        environment_variables = {
          SWXSOC_MISSION = "padre"
        }
        targets = []
      }
    },
  )

  support_role_name_by_project = {
    for project_name, project in local.support_projects :
    project_name => substr("swxsoc-codebuild-${replace(project_name, "_", "-")}", 0, 64)
  }

  existing_support_webhooks = toset([
    "padre-reprocessing-requests",
    "trigger_rebuild_padre_craft",
    "trigger_rebuild_padre_meddea",
    "trigger_rebuild_padre_sharp",
    "trigger_rebuild_swxsoc",
  ])

  codebuild_resource_metadata = merge(
    {
      for project_name, project in local.codebuild_projects :
      project_name => {
        mission = project.mission
        service = project.service
        purpose = contains(["architecture", "base-architecture"], project.kind) ? "Terraform deployment" : "Lambda image deployment"
      }
    },
    {
      for project_name, project in local.support_projects :
      project_name => {
        mission = project.mission
        service = project.service
        purpose = project.purpose
      }
    },
  )

  # These exact log groups already exist. The remaining managed project log
  # groups have never been created because their projects have not run yet.
  existing_codebuild_log_groups = toset([
    "build_aws_sdc_alert_lambda_function",
    "build_aws_sdc_executor_lambda_function",
    "build_hermes_sdc_aws_artifact_lambda",
    "build_hermes_sdc_aws_base_docker_image",
    "build_hermes_sdc_aws_pipeline_architecture",
    "build_hermes_sdc_aws_processing_lambda",
    "build_hermes_sdc_aws_sorting_lambda",
    "build_impax_sdc_aws_artifact_lambda",
    "build_impax_sdc_aws_base_docker_image",
    "build_impax_sdc_aws_processing_lambda",
    "build_impax_sdc_aws_sorting_lambda",
    "build_padre_sdc_aws_artifact_lambda",
    "build_padre_sdc_aws_base_docker_image",
    "build_padre_sdc_aws_concating_lambda",
    "build_padre_sdc_aws_pipeline_architecture",
    "build_padre_sdc_aws_processing_lambda",
    "build_padre_sdc_aws_sorting_lambda",
    "build_swxsoc_pipeline_sdc_aws_artifact_lambda",
    "build_swxsoc_pipeline_sdc_aws_base_docker_image",
    "build_swxsoc_pipeline_sdc_aws_pipeline_architecture",
    "build_swxsoc_pipeline_sdc_aws_processing_lambda",
    "build_swxsoc_pipeline_sdc_aws_sorting_lambda",
    "padre-reprocessing-requests",
    "trigger_rebuild_hermes_eea",
    "trigger_rebuild_padre_craft",
    "trigger_rebuild_padre_meddea",
    "trigger_rebuild_padre_sharp",
    "trigger_rebuild_swxsoc",
  ])
}

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = local.codebuild_resource_metadata

  name              = "/aws/codebuild/${each.key}"
  retention_in_days = var.codebuild_log_retention_days

  tags = {
    Environment = "Shared"
    ManagedBy   = "terraform"
    Mission     = each.value.mission
    Project     = each.value.mission
    Purpose     = each.value.purpose
    Service     = each.value.service
  }
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
      group_name  = aws_cloudwatch_log_group.codebuild[each.key].name
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

resource "aws_iam_role" "support_codebuild" {
  for_each = local.support_projects

  name = local.support_role_name_by_project[each.key]
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
    Purpose     = each.value.purpose
    Service     = each.value.service
  }
}

resource "aws_iam_role_policy" "support_codebuild" {
  for_each = local.support_projects

  name = "${local.support_role_name_by_project[each.key]}-policy"
  role = aws_iam_role.support_codebuild[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "BuildLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = "${aws_cloudwatch_log_group.codebuild[each.key].arn}:*"
        },
        {
          Sid    = "RepositoryConnection"
          Effect = "Allow"
          Action = [
            "codeconnections:UseConnection",
            "codestar-connections:UseConnection",
          ]
          Resource = each.value.connection_arn
        },
      ],
      each.value.kind == "dependency-trigger" ? tolist([
        {
          Sid      = "StartDeclaredBaseBuilds"
          Effect   = "Allow"
          Action   = tolist(["codebuild:StartBuild"])
          Resource = tolist([for target in each.value.targets : "arn:${data.aws_partition.current.partition}:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/${target}"])
        },
        ]) : tolist([
        {
          Sid      = "InvokeReprocessingLambda"
          Effect   = "Allow"
          Action   = tolist(["lambda:InvokeFunction"])
          Resource = tolist(["arn:${data.aws_partition.current.partition}:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"])
        },
        {
          Sid    = "ReadMissionObjects"
          Effect = "Allow"
          Action = tolist([
            "s3:GetObject",
            "s3:ListBucket",
            "s3:ListBucketVersions",
            "s3:ListBucketMultipartUploads",
          ])
          Resource = tolist(["*"])
        },
      ]),
    )
  })
}

resource "aws_codebuild_project" "support" {
  for_each = local.support_projects

  name                   = each.key
  description            = "${each.value.mission} ${each.value.service}"
  service_role           = aws_iam_role.support_codebuild[each.key].arn
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
    compute_type                = each.value.compute_type
    image                       = "aws/codebuild/standard:7.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false
    type                        = "LINUX_CONTAINER"

    dynamic "environment_variable" {
      for_each = each.value.environment_variables
      content {
        name  = environment_variable.key
        type  = "PLAINTEXT"
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      status      = "ENABLED"
      group_name  = aws_cloudwatch_log_group.codebuild[each.key].name
      stream_name = "build"
    }
  }

  source {
    type                = "GITHUB"
    location            = each.value.repository_url
    buildspec           = each.value.buildspec
    git_clone_depth     = each.value.git_clone_depth
    report_build_status = true

    auth {
      type     = "CODECONNECTIONS"
      resource = each.value.connection_arn
    }
  }

  tags = {
    Environment = "Shared"
    ManagedBy   = "terraform"
    Mission     = each.value.mission
    Project     = each.value.mission
    Purpose     = each.value.purpose
    Service     = each.value.service
  }
}

resource "aws_codebuild_webhook" "dependency_trigger" {
  for_each = local.dependency_trigger_projects

  project_name = aws_codebuild_project.support[each.key].name
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
}

resource "aws_codebuild_webhook" "reprocessing" {
  project_name = aws_codebuild_project.support["padre-reprocessing-requests"].name
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
}
