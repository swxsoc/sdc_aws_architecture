mock_provider "aws" {}

run "plan_deployment_projects" {
  command = plan

  variables {
    adopt_existing_codebuild_projects = false
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = data.aws_codestarconnections_connection.gdctb[0]
    values = {
      arn = "arn:aws:codeconnections:us-east-1:123456789012:connection/00000000-0000-0000-0000-000000000000"
    }
  }

  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name = "us-east-1"
    }
  }

  assert {
    condition     = length(resource.aws_codebuild_project.pipeline) == 35 && length(resource.aws_codebuild_project.support) == 12
    error_message = "The complete live fleet, its base deployment project, the GDCTB mission, and the demo mission should produce 47 managed CodeBuild projects."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.pipeline["build_demo_sdc_aws_base_docker_image"].source[0].location == "https://github.com/swxsoc/demo_sdc_aws_base_docker_image" &&
      resource.aws_codebuild_project.pipeline["build_demo_sdc_aws_base_docker_image"].source[0].auth[0].resource == var.shared_codeconnection_arn &&
      resource.aws_codebuild_project.pipeline["build_demo_sdc_aws_base_docker_image"].environment[0].privileged_mode &&
      resource.aws_codebuild_project.pipeline["build_demo_sdc_aws_sorting_lambda"].tags["Mission"] == "demo" &&
      resource.aws_codebuild_project.pipeline["build_demo_sdc_aws_sorting_lambda"].tags["Service"] == "sorting" &&
      !resource.aws_codebuild_project.pipeline["build_demo_sdc_aws_pipeline_architecture"].environment[0].privileged_mode &&
      contains(keys(resource.aws_codebuild_project.pipeline), "build_demo_sdc_aws_processing_lambda") &&
      contains(keys(resource.aws_codebuild_project.pipeline), "build_demo_sdc_aws_artifact_lambda") &&
      !contains(keys(resource.aws_codebuild_project.pipeline), "build_demo_sdc_aws_concating_lambda")
    )
    error_message = "The demo mission must get base, architecture, processing, sorting, and artifact projects on the shared SWxSOC connection, and no concating project."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_concating_lambda"].environment[0].privileged_mode &&
      resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_concating_lambda"].tags["Mission"] == "gdctb" &&
      resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_concating_lambda"].tags["Service"] == "concating" &&
      !resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_pipeline_architecture"].environment[0].privileged_mode &&
      resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_base_docker_image"].source[0].location == "https://github.com/GDC-Trailblazer/sdc_aws_base_docker_image"
    )
    error_message = "GDCTB must get base, architecture, and all four Lambda image projects, including concating, from its mission entry."
  }

  assert {
    condition     = resource.aws_codebuild_project.pipeline["build_padre_sdc_aws_concating_lambda"].environment[0].privileged_mode
    error_message = "Lambda image builds must enable Docker privileged mode."
  }

  assert {
    condition     = !resource.aws_codebuild_project.pipeline["build_padre_sdc_aws_pipeline_architecture"].environment[0].privileged_mode
    error_message = "Architecture validation/deployment builds do not need Docker privileged mode."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.pipeline["build_swxsoc_pipeline_sdc_aws_sorting_lambda"].source[0].buildspec == "buildspec.yml" &&
      resource.aws_codebuild_project.pipeline["build_swxsoc_pipeline_sdc_aws_sorting_lambda"].source[0].report_build_status
    )
    error_message = "Managed projects must consume the repository buildspec and report GitHub status."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].build_timeout > local.dependency_trigger_start_deadline_minutes &&
      local.dependency_trigger_start_deadline_minutes > resource.aws_codebuild_project.pipeline["build_padre_sdc_aws_base_docker_image"].build_timeout &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "+ ${local.dependency_trigger_start_deadline_minutes} * 60")
    )
    error_message = "A trigger must keep retrying past its target's build timeout and must outlive its own retry deadline."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_processing_lambda"].tags["Mission"] == "impax" &&
      resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_processing_lambda"].tags["Service"] == "processing" &&
      resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_processing_lambda"].tags["Environment"] == "Shared" &&
      resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_processing_lambda"].tags["ManagedBy"] == "terraform"
    )
    error_message = "Every project must carry uniform mission, service, environment, and ownership tags."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.pipeline["build_aws_sdc_alert_lambda_function"].environment[0].privileged_mode &&
      resource.aws_codebuild_project.pipeline["build_aws_sdc_alert_lambda_function"].tags["Service"] == "alert"
    )
    error_message = "The alert image build must be Docker-enabled and tagged as the alert service."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.pipeline["build_hermes_sdc_aws_sorting_lambda"].source[0].auth[0].resource == var.shared_codeconnection_arn &&
      resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_processing_lambda"].source[0].auth[0].resource == var.shared_codeconnection_arn &&
      resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_pipeline_architecture"].source[0].auth[0].resource == var.shared_codeconnection_arn &&
      resource.aws_codebuild_project.pipeline["build_hermes_sdc_aws_base_docker_image"].source[0].auth[0].resource == var.hermes_codeconnection_arn &&
      resource.aws_codebuild_project.pipeline["build_padre_sdc_aws_base_docker_image"].source[0].auth[0].resource == var.padre_codeconnection_arn &&
      resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_pipeline_architecture"].source[0].auth[0].resource == var.shared_codeconnection_arn &&
      length(resource.aws_codebuild_project.pipeline["build_impax_sdc_aws_base_docker_image"].source[0].auth) == 0 &&
      resource.aws_codebuild_project.pipeline["build_gdctb_sdc_aws_base_docker_image"].source[0].auth[0].resource == local.gdctb_codeconnection_arn &&
      resource.aws_codebuild_project.support["trigger_rebuild_gdctb_craft"].source[0].auth[0].resource == local.gdctb_codeconnection_arn &&
      resource.aws_codebuild_project.support["trigger_rebuild_gdctb_cape_eea"].source[0].auth[0].resource == local.gdctb_codeconnection_arn &&
      resource.aws_codebuild_project.support["trigger_rebuild_padre_craft"].source[0].auth[0].resource == var.padre_codeconnection_arn
    )
    error_message = "Each project must use the CodeConnection of the GitHub organization that owns its repository, or no connection when that organization has none."
  }

  assert {
    condition = (
      length(resource.aws_cloudwatch_log_group.codebuild) == 47 &&
      resource.aws_cloudwatch_log_group.codebuild["trigger_rebuild_hermes_core"].retention_in_days == 90 &&
      resource.aws_cloudwatch_log_group.codebuild["trigger_rebuild_hermes_core"].tags["Mission"] == "hermes"
    )
    error_message = "Every CodeBuild project must have a retained, mission-tagged log group."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].tags["Service"] == "dependency-rebuild" &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "SWxSOC BUILD: DEPENDENCY REBUILD TRIGGER") &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "build_impax_sdc_aws_base_docker_image") &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "start_target_build \"build_gdctb_sdc_aws_base_docker_image\"\n") &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "start_target_build \"build_demo_sdc_aws_base_docker_image\" DEVELOPMENT\n") &&
      !strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "start_target_build \"build_gdctb_sdc_aws_base_docker_image\" DEVELOPMENT")
    )
    error_message = "The SWxSOC dependency trigger must be tagged, bannered, and fan out to every mission base image."
  }

  assert {
    condition = (
      length(local.adopted_pipeline_projects) == 23 &&
      length(local.adopted_support_projects) == 10 &&
      !contains(keys(local.adopted_pipeline_projects), "build_gdctb_sdc_aws_base_docker_image") &&
      !contains(keys(local.adopted_pipeline_projects), "build_demo_sdc_aws_base_docker_image") &&
      !contains(keys(local.adopted_pipeline_projects), "build_demo_sdc_aws_pipeline_architecture") &&
      !contains(keys(local.adopted_pipeline_projects), "build_swxsoc_sdc_aws_base_architecture") &&
      !contains(keys(local.adopted_support_projects), "trigger_rebuild_gdctb_cape_eea") &&
      !contains(keys(local.adopted_support_projects), "trigger_rebuild_gdctb_craft") &&
      contains(keys(local.adopted_support_projects), "trigger_rebuild_padre_craft") &&
      contains(keys(local.adopted_pipeline_projects), "build_impax_sdc_aws_base_docker_image")
    )
    error_message = "With adoption enabled, the imports must cover exactly the 33 live projects and skip every new GDCTB and demo project, the GDCTB triggers, and the base architecture project."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.support["trigger_rebuild_gdctb_cape_eea"].tags["Mission"] == "gdctb" &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_gdctb_cape_eea"].source[0].buildspec, "start_target_build \"build_gdctb_sdc_aws_base_docker_image\"") &&
      !strcontains(resource.aws_codebuild_project.support["trigger_rebuild_gdctb_cape_eea"].source[0].buildspec, "build_padre_sdc_aws_base_docker_image")
    )
    error_message = "Each GDCTB instrument trigger must rebuild only the GDCTB base image."
  }

  assert {
    condition = (
      length(resource.aws_codebuild_webhook.image["build_demo_sdc_aws_base_docker_image"].filter_group) == 2 &&
      length(resource.aws_codebuild_webhook.image["build_demo_sdc_aws_processing_lambda"].filter_group) == 2 &&
      !anytrue(flatten([
        for group in resource.aws_codebuild_webhook.image["build_demo_sdc_aws_processing_lambda"].filter_group : [
          for filter in group.filter : filter.type == "HEAD_REF" && filter.pattern == "^refs/tags/.+"
        ]
      ])) &&
      length(resource.aws_codebuild_webhook.image["build_gdctb_sdc_aws_processing_lambda"].filter_group) == 3 &&
      anytrue(flatten([
        for group in resource.aws_codebuild_webhook.image["build_gdctb_sdc_aws_processing_lambda"].filter_group : [
          for filter in group.filter : filter.type == "HEAD_REF" && filter.pattern == "^refs/tags/.+"
        ]
      ])) &&
      length(resource.aws_codebuild_webhook.image["build_aws_sdc_executor_lambda_function"].filter_group) == 3
    )
    error_message = "Demo image webhooks must build on main and pull requests only, while live mission and shared image webhooks keep the release-tag filter."
  }

  assert {
    condition = (
      length(resource.aws_iam_role.codebuild) == 37 &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-demo-sorting-lambda"].path == "/" &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-demo-sorting-lambda"].tags["Mission"] == "demo" &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-demo-sorting-lambda"].tags["Service"] == "sorting" &&
      resource.aws_iam_role.codebuild["codebuild-trigger_rebuild-service-role"].path == "/service-role/" &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-swxsoc-base-architecture"].path == "/" &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-gdctb-processing-lambda"].path == "/" &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-gdctb-processing-lambda"].tags["Mission"] == "gdctb" &&
      resource.aws_iam_role.codebuild["swxsoc-codebuild-gdctb-processing-lambda"].tags["Service"] == "processing" &&
      resource.aws_iam_role.codebuild["padre-sdc-aws-base-docker-image"].tags["Mission"] == "padre" &&
      resource.aws_iam_role.codebuild["codebuild-trigger_rebuild-service-role"].tags["Service"] == "dependency-rebuild" &&
      resource.aws_iam_role_policy.codebuild["codebuild-trigger_rebuild-service-role"].name == "swxsoc-codebuild-managed"
    )
    error_message = "The 25 live service roles must be adopted under their existing names and paths, with new roles for the base architecture project and each GDCTB and demo project."
  }

  assert {
    condition = alltrue([
      for target in ["build_demo_sdc_aws_base_docker_image", "build_gdctb_sdc_aws_base_docker_image", "build_hermes_sdc_aws_base_docker_image", "build_impax_sdc_aws_base_docker_image", "build_padre_sdc_aws_base_docker_image", "build_swxsoc_pipeline_sdc_aws_base_docker_image"] :
      strcontains(resource.aws_iam_role_policy.codebuild["codebuild-trigger_rebuild-service-role"].policy, "project/${target}")
    ])
    error_message = "The shared trigger role's managed policy must cover every base image the eleven triggers start."
  }
}
