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
    condition     = length(resource.aws_codebuild_project.pipeline) == 22
    error_message = "The four missions plus executor should produce 22 managed CodeBuild projects."
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
}
