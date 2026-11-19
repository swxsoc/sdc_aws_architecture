# One account-wide CloudWatch dashboard that shows the pipeline status of every
# mission workspace, in the style of a public system-status page: a group per
# mission, a row per stage (land, sort, notify, process, record, reconcile),
# and the recent alarm events. It is rendered by a custom widget: the
# dashboard invokes lambda/status_widget with the viewer's own credentials and
# shows the HTML it returns, so nothing is exposed outside the console. The
# widget reads only the <env><mission>-pipeline-* alarms that the pipeline root
# creates per workspace; a workspace appears here as soon as its alarms exist.
#
# This root is the only one without per-environment workspaces, which is why
# the cross-environment dashboard lives here next to the CodeBuild fleet.
locals {
  status_dashboard_enabled    = var.enable_pipeline_status_dashboard
  status_dashboard_name       = "swxsoc-pipeline-status"
  status_widget_function_name = "swxsoc-pipeline-status-widget"

  status_tags = {
    Environment = "Shared"
    ManagedBy   = "terraform"
    Mission     = "swxsoc"
    Project     = "swxsoc"
    Purpose     = "Pipeline status dashboard"
    Service     = "pipeline-status"
  }

  status_dashboard_arn = "arn:${data.aws_partition.current.partition}:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/${local.status_dashboard_name}"
  status_dashboard_url = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${local.status_dashboard_name}"

  status_widget_environments = [
    { key = "prod", title = "Production" },
    { key = "dev", title = "Development" },
  ]

  # Built whether or not the dashboard is enabled (the dashboard resource is
  # what is gated), so the list keeps one type; one() yields null when the
  # function does not exist.
  status_dashboard_widgets = concat(
    [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown   = "# SWxSOC Pipeline Status\nOne group per mission workspace, one row per pipeline stage, derived from the `<env><mission>-pipeline-*` alarms. Open a mission to reach its own dashboard; open a stage's alarm name to reach the alarm. Turn on auto-refresh (top right) to keep it current."
          background = "transparent"
        }
      },
    ],
    [
      for index, environment in local.status_widget_environments : {
        type   = "custom"
        x      = 0
        y      = 2 + index * var.pipeline_status_widget_height
        width  = 24
        height = var.pipeline_status_widget_height
        properties = {
          endpoint = one(aws_lambda_function.pipeline_status_widget[*].arn)
          title    = environment.title
          params   = { environment = environment.key }
          updateOn = {
            refresh   = true
            resize    = true
            timeRange = false
          }
        }
      }
    ],
  )
}

data "archive_file" "pipeline_status_widget" {
  count       = local.status_dashboard_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/lambda/status_widget"
  excludes    = ["test_widget.py", "preview.py", "__pycache__"]
  output_path = "${path.module}/build/pipeline_status_widget.zip"
}

resource "aws_cloudwatch_log_group" "pipeline_status_widget" {
  count             = local.status_dashboard_enabled ? 1 : 0
  name              = "/aws/lambda/${local.status_widget_function_name}"
  retention_in_days = var.pipeline_status_log_retention_days
  tags              = local.status_tags
}

resource "aws_iam_role" "pipeline_status_widget" {
  count = local.status_dashboard_enabled ? 1 : 0
  name  = local.status_widget_function_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.status_tags
}

# Read-only: the widget describes alarms and their history, nothing else.
resource "aws_iam_role_policy" "pipeline_status_widget" {
  count = local.status_dashboard_enabled ? 1 : 0
  name  = "pipeline-status-widget"
  role  = aws_iam_role.pipeline_status_widget[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteOwnLog"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.pipeline_status_widget[0].arn}:*"
      },
      {
        Sid      = "ReadAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "pipeline_status_widget" {
  count         = local.status_dashboard_enabled ? 1 : 0
  function_name = local.status_widget_function_name
  description   = "Renders the SWxSOC pipeline status page for the ${local.status_dashboard_name} dashboard"
  role          = aws_iam_role.pipeline_status_widget[0].arn
  runtime       = "python3.12"
  handler       = "widget.handler"
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 30

  filename         = data.archive_file.pipeline_status_widget[0].output_path
  source_code_hash = data.archive_file.pipeline_status_widget[0].output_base64sha256

  environment {
    variables = {
      CONSOLE_REGION = data.aws_region.current.name
      HISTORY_DAYS   = tostring(var.pipeline_status_history_days)
    }
  }

  tags = local.status_tags

  depends_on = [
    aws_cloudwatch_log_group.pipeline_status_widget,
    aws_iam_role_policy.pipeline_status_widget,
  ]
}

resource "aws_cloudwatch_dashboard" "pipeline_status" {
  count          = local.status_dashboard_enabled ? 1 : 0
  dashboard_name = local.status_dashboard_name
  dashboard_body = jsonencode({ widgets = local.status_dashboard_widgets })
}

# A custom widget runs with the viewer's credentials, so whoever opens the
# dashboard needs to read it and to invoke the widget function. Console
# identities are managed outside this repository; attach this policy to the
# operator role or group that should see the page.
resource "aws_iam_policy" "pipeline_status_viewer" {
  count       = local.status_dashboard_enabled ? 1 : 0
  name        = "swxsoc-pipeline-status-viewer"
  description = "Lets a console user open the ${local.status_dashboard_name} dashboard and its status widget"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListDashboards"
        Effect   = "Allow"
        Action   = ["cloudwatch:ListDashboards"]
        Resource = "*"
      },
      {
        Sid      = "OpenStatusDashboard"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetDashboard"]
        Resource = local.status_dashboard_arn
      },
      {
        Sid      = "InvokeStatusWidget"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.pipeline_status_widget[0].arn
      },
    ]
  })

  tags = local.status_tags
}

output "pipeline_status_dashboard_url" {
  description = "Console URL of the pipeline status dashboard, when enabled"
  value       = local.status_dashboard_enabled ? local.status_dashboard_url : null
}

output "pipeline_status_viewer_policy_arn" {
  description = "IAM policy to attach to console identities that should see the pipeline status dashboard, when enabled"
  value       = local.status_dashboard_enabled ? aws_iam_policy.pipeline_status_viewer[0].arn : null
}
