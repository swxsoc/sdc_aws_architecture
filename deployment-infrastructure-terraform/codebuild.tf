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

  # Every live project already has a service role. Adopt those roles by name
  # rather than creating replacements: the role is imported and tagged, a
  # managed least-privilege inline policy is added beside whatever the role
  # carries today, and the legacy attached and inline policies are left alone
  # so no build loses a permission on the first apply. Retiring the legacy
  # policies is a separate, later change. Only the brand-new base
  # architecture project gets a role of its own.
  existing_service_roles = {
    build_aws_sdc_alert_lambda_function                 = "codebuild-build_aws_sdc_alert_lambda_function-service-role"
    build_aws_sdc_executor_lambda_function              = "codebuild-build_aws_sdc_executor_lambda_function-service-role"
    build_hermes_sdc_aws_artifact_lambda                = "codebuild-build_hermes_sdc_aws_artifact_lambda-service-role"
    build_hermes_sdc_aws_base_docker_image              = "codebuild-build_hermes_sdc_aws_base_docker_image-service-role"
    build_hermes_sdc_aws_pipeline_architecture          = "build_hermes_sdc_aws_pipeline_architecture-service-role"
    build_hermes_sdc_aws_processing_lambda              = "codebuild-build_hermes_sdc_aws_processing_lambda-service-role"
    build_hermes_sdc_aws_sorting_lambda                 = "codebuild-build_hermes_sdc_aws_sorting_lambda-role"
    build_impax_sdc_aws_artifact_lambda                 = "codebuild-build_impax_sdc_aws_artifact_lambda-service-role"
    build_impax_sdc_aws_base_docker_image               = "codebuild-build_impax_sdc_aws_base_docker_image-sr"
    build_impax_sdc_aws_pipeline_architecture           = "codebuild-build_impax_sdc_aws_pipeline_architecture-service-role"
    build_impax_sdc_aws_processing_lambda               = "codebuild-build_impax_sdc_aws_processing_lambda-service-role"
    build_impax_sdc_aws_sorting_lambda                  = "codebuild-build_impax_sdc_aws_sorting_lambda-service-role"
    build_padre_sdc_aws_artifact_lambda                 = "codebuild-build_padre_sdc_aws_artifact_lambda-service-role"
    build_padre_sdc_aws_base_docker_image               = "padre-sdc-aws-base-docker-image"
    build_padre_sdc_aws_concating_lambda                = "codebuild-build_padre_sdc_aws_concating_lambda-service-role"
    build_padre_sdc_aws_pipeline_architecture           = "codebuild-build_padre_sdc_aws_pipeline_architecture-service-role"
    build_padre_sdc_aws_processing_lambda               = "codebuild-build_padre_sdc_aws_processing_lambda-service-role"
    build_padre_sdc_aws_sorting_lambda                  = "codebuild-build_padre_sdc_aws_sorting_lambda-service-role"
    build_swxsoc_pipeline_sdc_aws_artifact_lambda       = "codebuild-build_sdc_aws_artifact_lambda-service-role"
    build_swxsoc_pipeline_sdc_aws_base_docker_image     = "codebuild-build_swxsoc_pipeline_sdc_aws_base_docker_image-sr"
    build_swxsoc_pipeline_sdc_aws_pipeline_architecture = "codebuild-build_swxsoc_pipeline_sdc_aws_pipeline_architecture-sr"
    build_swxsoc_pipeline_sdc_aws_processing_lambda     = "codebuild-build_swxsoc_pipeline_sdc_aws_processing_lambda-sr"
    build_swxsoc_pipeline_sdc_aws_sorting_lambda        = "codebuild-build_swxsoc_pipeline_sdc_aws_sorting_lambda-sr"
    padre-reprocessing-requests                         = "codebuild-padre-reprocessing-pipeline-service-role"
    trigger_rebuild_hermes_core                         = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_hermes_eea                          = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_hermes_merit                        = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_hermes_nemisis                      = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_hermes_spani                        = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_padre_craft                         = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_padre_meddea                        = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_padre_sharp                         = "codebuild-trigger_rebuild-service-role"
    trigger_rebuild_swxsoc                              = "codebuild-trigger_rebuild-service-role"
  }

  new_service_roles = {
    build_swxsoc_sdc_aws_base_architecture = "swxsoc-codebuild-swxsoc-base-architecture"
  }

  project_role_name = merge(local.existing_service_roles, local.new_service_roles)

  # One record per role, describing every project that runs under it, so the
  # managed policy grants the union of what those projects need.
  # Exactly which projects each image build may start: component images hand
  # off to their mission's architecture project, executor and alert hand off
  # to the base architecture project, and base images fan out to their
  # mission's Lambda builds. Architecture projects start nothing.
  image_start_targets = {
    for project_name, project in local.codebuild_projects :
    project_name => (
      project.kind != "image" ? [] :
      contains(["executor", "alert"], project.service) ? ["build_swxsoc_sdc_aws_base_architecture"] :
      project.service == "container-base" ? [
        for name, candidate in local.mission_lambda_projects : name if candidate.mission == project.mission
      ] :
      ["build_${project.mission}_sdc_aws_pipeline_architecture"]
    )
  }

  all_managed_projects = merge(
    {
      for project_name, project in local.codebuild_projects :
      project_name => merge(project, {
        purpose = contains(["architecture", "base-architecture"], project.kind) ? "Terraform deployment" : "Lambda image deployment"
        targets = local.image_start_targets[project_name]
      })
    },
    local.support_projects,
  )

  service_roles = {
    for role_name in distinct(values(local.project_role_name)) :
    role_name => {
      path            = contains(values(local.new_service_roles), role_name) ? "/" : "/service-role/"
      projects        = sort([for project_name, name in local.project_role_name : project_name if name == role_name])
      kinds           = distinct([for project_name, name in local.project_role_name : local.all_managed_projects[project_name].kind if name == role_name])
      connection_arns = distinct(compact([for project_name, name in local.project_role_name : local.all_managed_projects[project_name].connection_arn if name == role_name]))
      targets         = distinct(flatten([for project_name, name in local.project_role_name : local.all_managed_projects[project_name].targets if name == role_name]))
      missions        = distinct([for project_name, name in local.project_role_name : local.all_managed_projects[project_name].mission if name == role_name])
      services        = distinct([for project_name, name in local.project_role_name : local.all_managed_projects[project_name].service if name == role_name])
      purposes        = distinct([for project_name, name in local.project_role_name : local.all_managed_projects[project_name].purpose if name == role_name])
    }
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
  for_each = local.service_roles

  name = each.key
  path = each.value.path
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
    Mission     = length(each.value.missions) == 1 ? each.value.missions[0] : "swxsoc"
    Project     = length(each.value.missions) == 1 ? each.value.missions[0] : "swxsoc"
    Purpose     = length(each.value.purposes) == 1 ? each.value.purposes[0] : "CodeBuild"
    Service     = length(each.value.services) == 1 ? each.value.services[0] : "shared"
  }

  lifecycle {
    # Adopted roles keep their console descriptions and any policies that were
    # attached or written inline before Terraform took over.
    ignore_changes = [description]
  }
}

# The managed policy sits beside the legacy policies on each adopted role. It
# grants exactly what the projects under that role need, so the legacy
# policies can be detached one role at a time once builds are verified.
resource "aws_iam_role_policy" "codebuild" {
  for_each = local.service_roles

  name = "swxsoc-codebuild-managed"
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
          Resource = flatten([
            for project_name in each.value.projects : [
              "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${project_name}",
              "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${project_name}:*",
            ]
          ])
        },
      ],
      length(each.value.connection_arns) > 0 ? [
        {
          Sid    = "RepositoryConnection"
          Effect = "Allow"
          Action = [
            "codeconnections:UseConnection",
            "codestar-connections:UseConnection",
          ]
          Resource = each.value.connection_arns
        },
      ] : [],
      contains(each.value.kinds, "image") ? [
        {
          Sid    = "ContainerRegistry"
          Effect = "Allow"
          Action = [
            "ecr:*",
            "ecr-public:*",
            "sts:GetServiceBearerToken",
          ]
          Resource = ["*"]
        },
      ] : [],
      length(each.value.targets) > 0 ? [
        {
          Sid      = "StartDeclaredDownstreamBuilds"
          Effect   = "Allow"
          Action   = ["codebuild:StartBuild"]
          Resource = [for target in sort(each.value.targets) : "arn:${data.aws_partition.current.partition}:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/${target}"]
        },
      ] : [],
      contains(each.value.kinds, "architecture") || contains(each.value.kinds, "base-architecture") ? [
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
          Resource = ["*"]
        },
      ] : [],
      contains(each.value.kinds, "reprocessing") ? [
        {
          Sid      = "InvokeReprocessingLambda"
          Effect   = "Allow"
          Action   = ["lambda:InvokeFunction"]
          Resource = ["arn:${data.aws_partition.current.partition}:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"]
        },
        {
          Sid    = "ReadMissionObjects"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:ListBucket",
            "s3:ListBucketVersions",
            "s3:ListBucketMultipartUploads",
          ]
          Resource = ["*"]
        },
      ] : [],
    )
  })
}

resource "aws_codebuild_project" "pipeline" {
  for_each = local.codebuild_projects

  name                   = each.key
  description            = "${each.value.mission} ${each.value.service} build and deployment"
  service_role           = aws_iam_role.codebuild[local.project_role_name[each.key]].arn
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

resource "aws_codebuild_project" "support" {
  for_each = local.support_projects

  name                   = each.key
  description            = "${each.value.mission} ${each.value.service}"
  service_role           = aws_iam_role.codebuild[local.project_role_name[each.key]].arn
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
