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
    condition     = length(resource.aws_codebuild_project.pipeline) == 24 && length(resource.aws_codebuild_project.support) == 10
    error_message = "The complete live fleet plus its base deployment project should produce 34 managed CodeBuild projects."
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
      length(resource.aws_cloudwatch_log_group.codebuild) == 34 &&
      resource.aws_cloudwatch_log_group.codebuild["trigger_rebuild_hermes_core"].retention_in_days == 90 &&
      resource.aws_cloudwatch_log_group.codebuild["trigger_rebuild_hermes_core"].tags["Mission"] == "hermes"
    )
    error_message = "Every CodeBuild project must have a retained, mission-tagged log group."
  }

  assert {
    condition = (
      resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].tags["Service"] == "dependency-rebuild" &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "SWxSOC BUILD: DEPENDENCY REBUILD TRIGGER") &&
      strcontains(resource.aws_codebuild_project.support["trigger_rebuild_swxsoc"].source[0].buildspec, "build_impax_sdc_aws_base_docker_image")
    )
    error_message = "The SWxSOC dependency trigger must be tagged, bannered, and fan out to every mission base image."
  }
}
