# The demo mission exists to prove the pipeline works, so it gets a smoke
# test: a support project that drops one synthetic file into the dev-demo
# incoming bucket and verifies that sorting, processing, and artifacts each
# acted on it (sorted copy, processed output, Timestream record, Mattermost
# post, and optionally the MetaTracker row). It runs scripts/demo_smoke_test.py
# from this repository on a schedule and on demand, and fails the build when
# any stage is missing. The schedule starts disabled: enable it once the
# dev-demo workspace is bootstrapped and a demo instrument package exists,
# otherwise every run fails at the processing stage.
locals {
  demo_smoke_test = {
    mission    = "demo"
    instrument = "craft"
    # These are the dev-demo names pipeline-infrastructure-terraform/demo.tfvars
    # produces; this root has no view of that workspace, so they are spelled
    # out here and checked by the deployment tests.
    incoming_bucket     = "dev-demo-swsoc-incoming"
    instrument_buckets  = ["dev-demo-craft"]
    timestream_database = "dev-demo_sdc_aws_logs"
    timestream_table    = "dev-demo_sdc_aws_s3_bucket_log_table"
    secret_path_root    = "swxsoc/dev/demo"
  }

  demo_smoke_test_buckets = concat([local.demo_smoke_test.incoming_bucket], local.demo_smoke_test.instrument_buckets)

  demo_smoke_test_support_projects = {
    demo-smoke-test = {
      name           = "demo-smoke-test"
      mission        = local.demo_smoke_test.mission
      service        = "smoke-test"
      kind           = "smoke-test"
      purpose        = "Demo mission smoke test"
      repository_url = "https://github.com/swxsoc/sdc_aws_architecture"
      connection_arn = var.shared_codeconnection_arn
      buildspec = templatefile("${path.module}/buildspecs/demo-smoke-test.yml.tftpl", {
        mission = local.demo_smoke_test.mission
      })
      build_timeout   = 45
      compute_type    = "BUILD_GENERAL1_SMALL"
      git_clone_depth = 1
      # The MetaTracker check needs a network path to the RDS instance, whose
      # security group admits the Lambda and Grafana security groups only; a
      # CodeBuild project outside the VPC has neither, so the scheduled run
      # skips that check. Run the script by hand from an allowed host to
      # include it.
      environment_variables = {
        SWXSOC_MISSION        = local.demo_smoke_test.mission
        SMOKE_TEST_INSTRUMENT = local.demo_smoke_test.instrument
        SMOKE_TEST_ARGS       = "--skip-rds"
      }
      targets = []
    }
  }
}

# EventBridge starts the project on the schedule through a role of its own;
# the project's service role is for the build, not for starting it.
resource "aws_iam_role" "demo_smoke_test_schedule" {
  name = "swxsoc-events-demo-smoke-test"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "events.amazonaws.com"
      }
    }]
  })

  tags = {
    Mission = local.demo_smoke_test.mission
    Project = local.demo_smoke_test.mission
    Purpose = "Demo mission smoke test"
    Service = "smoke-test"
  }
}

resource "aws_iam_role_policy" "demo_smoke_test_schedule" {
  name = "start-demo-smoke-test"
  role = aws_iam_role.demo_smoke_test_schedule.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StartSmokeTest"
      Effect   = "Allow"
      Action   = ["codebuild:StartBuild"]
      Resource = [aws_codebuild_project.support["demo-smoke-test"].arn]
    }]
  })
}

resource "aws_cloudwatch_event_rule" "demo_smoke_test" {
  name                = "demo-smoke-test-schedule"
  description         = "Starts the demo mission smoke test on a schedule"
  schedule_expression = var.demo_smoke_test_schedule
  state               = var.enable_demo_smoke_test_schedule ? "ENABLED" : "DISABLED"

  tags = {
    Mission = local.demo_smoke_test.mission
    Project = local.demo_smoke_test.mission
    Purpose = "Demo mission smoke test"
    Service = "smoke-test"
  }
}

resource "aws_cloudwatch_event_target" "demo_smoke_test" {
  rule      = aws_cloudwatch_event_rule.demo_smoke_test.name
  target_id = "demo-smoke-test"
  arn       = aws_codebuild_project.support["demo-smoke-test"].arn
  role_arn  = aws_iam_role.demo_smoke_test_schedule.arn
}
