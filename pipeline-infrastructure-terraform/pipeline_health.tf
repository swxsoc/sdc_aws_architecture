// Pipeline health: the feedback loop for one mission workspace.
//
// Every stage of the chain (land, sort, notify, process, record) gets an
// alarm, a scheduled reconciliation compares the mission buckets with the
// MetaTracker and Timestream records, a composite alarm rolls everything up,
// and a dashboard shows the chain left to right. Everything here is new and
// additive: no bucket, topic, queue, Lambda, role or policy that already
// exists is changed. See docs/user-guide/pipeline-health.rst for the design,
// the stage/evidence/alarm/gap table and the operating notes.

locals {
  enable_pipeline_alarms         = var.enable_pipeline_alarms
  enable_pipeline_reconciliation = var.enable_pipeline_reconciliation
  enable_pipeline_notifier       = local.enable_pipeline_alarms && var.enable_pipeline_alerts_mattermost

  # dev-padre-pipeline / padre-pipeline
  health_prefix = "${local.environment_short_name}${local.mission_slug}-pipeline"
  # SWxSOC/Pipeline/dev-padre: the log metric filters and the reconciliation
  # Lambda publish here, the alarms and dashboard read from here.
  health_metric_namespace = "SWxSOC/Pipeline/${local.environment_slug}-${local.mission_slug}"
  health_tags             = merge(local.standard_tags, { "Service" = "pipeline-health" })

  instrument_by_bucket = zipmap(local.instrument_bucket_names, local.instrument_names)

  # The Lambda stages that exist in this workspace, with the log patterns
  # that mean a stage failed on a file. The handlers catch every exception
  # and return a 500 body, so AWS/Lambda Errors alone misses most failures;
  # the patterns below are the lines the sources write on those paths.
  # The artifacts handler logs its failures as {'status': 'ERROR', ...}
  # lines ("Error Processing Artifacts" is only in the response it returns,
  # never in the log), and so do the comms clients. Comms (Slack/Mattermost)
  # errors do not affect the data record and PADRE's artifacts log one on
  # every file, so every line that names a comms platform is excluded.
  monitored_lambdas = merge(
    local.enable_sorting_lambda ? {
      sorting = {
        function_name     = aws_lambda_function.sorting_lambda_function[0].function_name
        timeout           = aws_lambda_function.sorting_lambda_function[0].timeout
        log_group         = aws_cloudwatch_log_group.sorting[0].name
        log_error_pattern = "?\"Issue parsing file\" ?\"Error sorting file\" ?\"does not exist in bucket\""
      }
    } : {},
    local.enable_processing_lambda ? {
      processing = {
        function_name     = aws_lambda_function.aws_sdc_processing_lambda_function[0].function_name
        timeout           = aws_lambda_function.aws_sdc_processing_lambda_function[0].timeout
        log_group         = aws_cloudwatch_log_group.processing[0].name
        log_error_pattern = "?\"Error Processing Event\" ?\"'status': 'ERROR'\""
      }
    } : {},
    local.enable_artifacts_lambda ? {
      artifacts = {
        function_name     = aws_lambda_function.aws_sdc_artifacts_lambda_function[0].function_name
        timeout           = aws_lambda_function.aws_sdc_artifacts_lambda_function[0].timeout
        log_group         = aws_cloudwatch_log_group.artifacts[0].name
        log_error_pattern = "\"'status': 'ERROR'\" -\"comms client\" -\"Slack\" -\"slack\" -\"Mattermost\" -\"mattermost\" -\"message_ts\""
      }
    } : {},
    local.enable_concating_lambda ? {
      concating = {
        function_name     = aws_lambda_function.aws_sdc_concating_lambda_function[0].function_name
        timeout           = aws_lambda_function.aws_sdc_concating_lambda_function[0].timeout
        log_group         = aws_cloudwatch_log_group.concating[0].name
        log_error_pattern = "?\"ERROR:\" ?\"Traceback\""
      }
    } : {},
  )
  lambda_alarm_targets = local.enable_pipeline_alarms ? local.monitored_lambdas : {}
  lambda_alarm_kinds   = ["errors", "throttles", "duration", "log-errors"]

  reconciliation_function_name = "${local.environment_short_name}${var.mission_name}_pipeline_reconciliation"
  notifier_function_name       = "${local.environment_short_name}${var.mission_name}_pipeline_alert_notifier"
  reconciliation_period        = var.pipeline_reconciliation_interval_minutes * 60
  reconciliation_schedule      = "rate(${var.pipeline_reconciliation_interval_minutes} minute${var.pipeline_reconciliation_interval_minutes == 1 ? "" : "s"})"
  # The RDS security group admits the Lambda security group, so the database
  # check needs the VPC. Without it the check is skipped, and says so.
  reconciliation_checks_rds = var.enable_lambda_vpc

  # Alarms on the reconciliation metrics: name suffix => metric. Each alarms
  # when the latest run reported a non-zero count.
  reconciliation_count_alarms = {
    "unsorted-incoming-objects"   = "UnsortedIncomingObjects"
    "missing-metatracker-rows"    = "MissingMetaTrackerRows"
    "missing-timestream-records"  = "MissingTimestreamRecords"
    "reconciliation-check-errors" = "ReconciliationCheckErrors"
  }
  reconciliation_alarm_targets = local.enable_pipeline_alarms && local.enable_pipeline_reconciliation ? local.reconciliation_count_alarms : {}

  # Every alarm name this workspace creates, built from configuration so the
  # composite alarm's rule and count are known at plan time.
  pipeline_alarm_names = local.enable_pipeline_alarms ? concat(
    flatten([for stage in keys(local.monitored_lambdas) : [for kind in local.lambda_alarm_kinds : "${local.health_prefix}-${stage}-${kind}"]]),
    [for bucket in local.instrument_bucket_names : "${local.health_prefix}-${local.instrument_by_bucket[bucket]}-topic-delivery-failures"],
    [for bucket in local.instrument_bucket_names : "${local.health_prefix}-${local.instrument_by_bucket[bucket]}-queue-age"],
    local.enable_pipeline_reconciliation ? concat(
      [for suffix in keys(local.reconciliation_count_alarms) : "${local.health_prefix}-${suffix}"],
      ["${local.health_prefix}-reconciliation-not-running", "${local.health_prefix}-reconciliation-errors"],
    ) : [],
  ) : []
}

///////////////////////////////////////
// Alert topic
///////////////////////////////////////

resource "aws_sns_topic" "pipeline_alerts" {
  count = local.enable_pipeline_alarms ? 1 : 0
  name  = "${local.health_prefix}-alerts"
  tags  = local.health_tags
}

resource "aws_sns_topic_subscription" "pipeline_alert_emails" {
  for_each  = local.enable_pipeline_alarms ? toset(var.pipeline_alert_emails) : toset([])
  topic_arn = aws_sns_topic.pipeline_alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  pipeline_alarm_actions = local.enable_pipeline_alarms ? [aws_sns_topic.pipeline_alerts[0].arn] : []
}

///////////////////////////////////////
// Lambda stage alarms
///////////////////////////////////////

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = local.lambda_alarm_targets
  alarm_name          = "${local.health_prefix}-${each.key}-errors"
  alarm_description   = "The ${each.key} Lambda of ${terraform.workspace} reported invocation errors (crashes outside its handler, timeouts, out of memory)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each            = local.lambda_alarm_targets
  alarm_name          = "${local.health_prefix}-${each.key}-throttles"
  alarm_description   = "The ${each.key} Lambda of ${terraform.workspace} was throttled; events may have been dropped."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each            = local.lambda_alarm_targets
  alarm_name          = "${local.health_prefix}-${each.key}-duration"
  alarm_description   = "The ${each.key} Lambda of ${terraform.workspace} ran for at least ${var.pipeline_lambda_duration_alarm_fraction * 100}% of its ${each.value.timeout}s timeout and is about to be killed mid-file."
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = each.value.function_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = floor(each.value.timeout * 1000 * var.pipeline_lambda_duration_alarm_fraction)
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

resource "aws_cloudwatch_log_metric_filter" "lambda_log_errors" {
  for_each       = local.lambda_alarm_targets
  name           = "${local.health_prefix}-${each.key}-log-errors"
  log_group_name = each.value.log_group
  pattern        = each.value.log_error_pattern

  metric_transformation {
    name          = "${title(each.key)}LogErrors"
    namespace     = local.health_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_log_errors" {
  for_each            = local.lambda_alarm_targets
  alarm_name          = "${local.health_prefix}-${each.key}-log-errors"
  alarm_description   = "The ${each.key} Lambda of ${terraform.workspace} logged a failure on a file. Its handler swallows exceptions, so this is the error signal; the log group has the file key and traceback."
  namespace           = local.health_metric_namespace
  metric_name         = aws_cloudwatch_log_metric_filter.lambda_log_errors[each.key].metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

///////////////////////////////////////
// Notify stage alarms (per instrument)
///////////////////////////////////////

resource "aws_cloudwatch_metric_alarm" "topic_delivery_failures" {
  for_each            = local.enable_pipeline_alarms ? aws_sns_topic.sns_topics : {}
  alarm_name          = "${local.health_prefix}-${local.instrument_by_bucket[each.key]}-topic-delivery-failures"
  alarm_description   = "SNS could not deliver a ${each.key} object notification to a subscriber (processing or artifacts Lambda, or the instrument queue)."
  namespace           = "AWS/SNS"
  metric_name         = "NumberOfNotificationsFailed"
  dimensions          = { TopicName = each.value.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each            = local.enable_pipeline_alarms ? aws_sqs_queue.sqs_queue : {}
  alarm_name          = "${local.health_prefix}-${local.instrument_by_bucket[each.key]}-queue-age"
  alarm_description   = "The oldest message in the ${each.key} queue is older than ${var.pipeline_sqs_oldest_message_age_threshold_seconds}s: the external consumer has stopped draining it."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = each.value.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.pipeline_sqs_oldest_message_age_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

///////////////////////////////////////
// Reconciliation Lambda
///////////////////////////////////////

data "archive_file" "pipeline_reconciliation" {
  count       = local.enable_pipeline_reconciliation ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/lambda/reconciliation"
  excludes    = ["test_reconcile.py", "test_pgwire.py", "__pycache__"]
  output_path = "${path.module}/build/pipeline_reconciliation.zip"
}

resource "aws_cloudwatch_log_group" "pipeline_reconciliation" {
  count             = local.enable_pipeline_reconciliation ? 1 : 0
  name              = "/aws/lambda/${local.reconciliation_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = local.health_tags
}

resource "aws_iam_role" "pipeline_reconciliation" {
  count = local.enable_pipeline_reconciliation ? 1 : 0
  name  = "${local.environment_short_name}${var.mission_name}_pipeline_reconciliation_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.health_tags
}

resource "aws_iam_role_policy" "pipeline_reconciliation" {
  count = local.enable_pipeline_reconciliation ? 1 : 0
  name  = "pipeline-reconciliation"
  role  = aws_iam_role.pipeline_reconciliation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "WriteOwnLog"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.pipeline_reconciliation[0].arn}:*"
        },
        {
          Sid      = "ListMissionBuckets"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = [for bucket in local.bucket_list : aws_s3_bucket.sdc_buckets[bucket].arn]
        },
        {
          Sid    = "QueryMissionTimestream"
          Effect = "Allow"
          Action = ["timestream:Select", "timestream:DescribeTable", "timestream:ListMeasures"]
          Resource = [
            aws_timestreamwrite_table.sdc_aws_timestream_table.arn,
          ]
        },
        {
          Sid      = "DescribeTimestream"
          Effect   = "Allow"
          Action   = ["timestream:DescribeEndpoints", "timestream:SelectValues", "timestream:CancelQuery"]
          Resource = "*"
        },
        {
          Sid      = "ReadRdsSecret"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = aws_secretsmanager_secret.rds_secret.arn
        },
        {
          Sid      = "DecryptRdsSecret"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = aws_kms_key.default.arn
        },
      ],
      [
        {
          Sid       = "PublishHealthMetrics"
          Effect    = "Allow"
          Action    = ["cloudwatch:PutMetricData"]
          Resource  = "*"
          Condition = { StringEquals = { "cloudwatch:namespace" = local.health_metric_namespace } }
        },
      ],
      var.enable_lambda_vpc ? [
        {
          Sid    = "ManageVpcInterfaces"
          Effect = "Allow"
          Action = [
            "ec2:CreateNetworkInterface",
            "ec2:DescribeNetworkInterfaces",
            "ec2:DescribeSubnets",
            "ec2:DeleteNetworkInterface",
            "ec2:AssignPrivateIpAddresses",
            "ec2:UnassignPrivateIpAddresses",
          ]
          Resource = "*"
        },
      ] : [],
    )
  })
}

resource "aws_lambda_function" "pipeline_reconciliation" {
  count         = local.enable_pipeline_reconciliation ? 1 : 0
  function_name = local.reconciliation_function_name
  description   = "Compares the ${terraform.workspace} buckets with MetaTracker and Timestream and publishes ${local.health_metric_namespace} metrics"
  role          = aws_iam_role.pipeline_reconciliation[0].arn
  runtime       = "python3.12"
  handler       = "reconcile.handler"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 900

  filename         = data.archive_file.pipeline_reconciliation[0].output_path
  source_code_hash = data.archive_file.pipeline_reconciliation[0].output_base64sha256

  environment {
    variables = {
      MISSION             = var.mission_name
      ENVIRONMENT         = local.environment_slug
      INCOMING_BUCKET     = aws_s3_bucket.sdc_buckets[var.incoming_bucket_name].bucket
      INSTRUMENT_BUCKETS  = join(",", [for bucket in local.instrument_bucket_names : aws_s3_bucket.sdc_buckets[bucket].bucket])
      DATA_LEVELS         = join(",", local.data_levels)
      TIMESTREAM_DATABASE = aws_timestreamwrite_database.sdc_aws_timestream_db.database_name
      TIMESTREAM_TABLE    = aws_timestreamwrite_table.sdc_aws_timestream_table.table_name
      METRIC_NAMESPACE    = local.health_metric_namespace
      WINDOW_HOURS        = tostring(var.pipeline_reconciliation_window_hours)
      GRACE_MINUTES       = tostring(var.pipeline_reconciliation_grace_minutes)
      IGNORE_KEY_REGEX    = var.pipeline_reconciliation_ignore_key_regex
      RDS_SECRET_ARN      = aws_secretsmanager_secret.rds_secret.arn
      SKIP_RDS            = local.reconciliation_checks_rds ? "false" : "true"
    }
  }

  dynamic "vpc_config" {
    for_each = var.enable_lambda_vpc ? [1] : []
    content {
      subnet_ids         = var.lambda_vpc_subnet_ids
      security_group_ids = [aws_security_group.lambda_sg.id]
    }
  }

  tags = local.health_tags

  depends_on = [
    aws_cloudwatch_log_group.pipeline_reconciliation,
    aws_iam_role_policy.pipeline_reconciliation,
  ]
}

resource "aws_cloudwatch_event_rule" "pipeline_reconciliation" {
  count               = local.enable_pipeline_reconciliation ? 1 : 0
  name                = "${local.reconciliation_function_name}-schedule"
  description         = "Runs the ${terraform.workspace} pipeline reconciliation"
  schedule_expression = local.reconciliation_schedule
  tags                = local.health_tags
}

resource "aws_cloudwatch_event_target" "pipeline_reconciliation" {
  count     = local.enable_pipeline_reconciliation ? 1 : 0
  rule      = aws_cloudwatch_event_rule.pipeline_reconciliation[0].name
  target_id = "pipeline-reconciliation"
  arn       = aws_lambda_function.pipeline_reconciliation[0].arn
}

resource "aws_lambda_permission" "pipeline_reconciliation_schedule" {
  count         = local.enable_pipeline_reconciliation ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_reconciliation[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_reconciliation[0].arn
}

///////////////////////////////////////
// Reconciliation alarms
///////////////////////////////////////

resource "aws_cloudwatch_metric_alarm" "reconciliation_counts" {
  for_each            = local.reconciliation_alarm_targets
  alarm_name          = "${local.health_prefix}-${each.key}"
  alarm_description   = "The last ${terraform.workspace} reconciliation run reported ${each.value} > 0; the run's log entry lists the keys."
  namespace           = local.health_metric_namespace
  metric_name         = each.value
  statistic           = "Maximum"
  period              = local.reconciliation_period
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

resource "aws_cloudwatch_metric_alarm" "reconciliation_not_running" {
  count               = local.enable_pipeline_alarms && local.enable_pipeline_reconciliation ? 1 : 0
  alarm_name          = "${local.health_prefix}-reconciliation-not-running"
  alarm_description   = "The ${terraform.workspace} reconciliation has not reported for two scheduled periods; the pipeline is unwatched."
  namespace           = local.health_metric_namespace
  metric_name         = "ReconciliationRuns"
  statistic           = "Sum"
  period              = local.reconciliation_period
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

resource "aws_cloudwatch_metric_alarm" "reconciliation_errors" {
  count               = local.enable_pipeline_alarms && local.enable_pipeline_reconciliation ? 1 : 0
  alarm_name          = "${local.health_prefix}-reconciliation-errors"
  alarm_description   = "The ${terraform.workspace} reconciliation Lambda itself failed."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.pipeline_reconciliation[0].function_name }
  statistic           = "Sum"
  period              = local.reconciliation_period
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.pipeline_alarm_actions
  ok_actions          = local.pipeline_alarm_actions
  tags                = local.health_tags
}

///////////////////////////////////////
// Composite alarm
///////////////////////////////////////

resource "aws_cloudwatch_composite_alarm" "pipeline_unhealthy" {
  count             = local.enable_pipeline_alarms && length(local.pipeline_alarm_names) > 0 ? 1 : 0
  alarm_name        = "${local.health_prefix}-unhealthy"
  alarm_description = "A stage of the ${terraform.workspace} pipeline is unhealthy. The triggering alarm names the stage."
  alarm_rule        = join(" OR ", [for name in local.pipeline_alarm_names : "ALARM(\"${name}\")"])
  alarm_actions     = local.pipeline_alarm_actions
  ok_actions        = local.pipeline_alarm_actions
  tags              = local.health_tags

  depends_on = [
    aws_cloudwatch_metric_alarm.lambda_errors,
    aws_cloudwatch_metric_alarm.lambda_throttles,
    aws_cloudwatch_metric_alarm.lambda_duration,
    aws_cloudwatch_metric_alarm.lambda_log_errors,
    aws_cloudwatch_metric_alarm.topic_delivery_failures,
    aws_cloudwatch_metric_alarm.queue_age,
    aws_cloudwatch_metric_alarm.reconciliation_counts,
    aws_cloudwatch_metric_alarm.reconciliation_not_running,
    aws_cloudwatch_metric_alarm.reconciliation_errors,
  ]
}

///////////////////////////////////////
// Mattermost route (opt in)
///////////////////////////////////////

data "archive_file" "pipeline_alert_notifier" {
  count       = local.enable_pipeline_notifier ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/lambda/alert_notifier"
  excludes    = ["test_notifier.py", "__pycache__"]
  output_path = "${path.module}/build/pipeline_alert_notifier.zip"
}

resource "aws_cloudwatch_log_group" "pipeline_alert_notifier" {
  count             = local.enable_pipeline_notifier ? 1 : 0
  name              = "/aws/lambda/${local.notifier_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = local.health_tags
}

resource "aws_iam_role" "pipeline_alert_notifier" {
  count = local.enable_pipeline_notifier ? 1 : 0
  name  = "${local.environment_short_name}${var.mission_name}_pipeline_alert_notifier_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.health_tags
}

resource "aws_iam_role_policy" "pipeline_alert_notifier" {
  count = local.enable_pipeline_notifier ? 1 : 0
  name  = "pipeline-alert-notifier"
  role  = aws_iam_role.pipeline_alert_notifier[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteOwnLog"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.pipeline_alert_notifier[0].arn}:*"
    }]
  })
}

resource "aws_lambda_function" "pipeline_alert_notifier" {
  count         = local.enable_pipeline_notifier ? 1 : 0
  function_name = local.notifier_function_name
  description   = "Posts ${terraform.workspace} pipeline alarm transitions to Mattermost"
  role          = aws_iam_role.pipeline_alert_notifier[0].arn
  runtime       = "python3.12"
  handler       = "notifier.handler"
  architectures = ["arm64"]
  memory_size   = 128
  timeout       = 30

  filename         = data.archive_file.pipeline_alert_notifier[0].output_path
  source_code_hash = data.archive_file.pipeline_alert_notifier[0].output_base64sha256

  environment {
    variables = {
      MATTERMOST_URL        = var.mattermost_url
      MATTERMOST_CHANNEL_ID = local.mattermost_credentials.channel_id
      MATTERMOST_TOKEN      = local.mattermost_credentials.token
    }
  }

  tags = local.health_tags

  depends_on = [
    aws_cloudwatch_log_group.pipeline_alert_notifier,
    aws_iam_role_policy.pipeline_alert_notifier,
  ]
}

resource "aws_lambda_permission" "pipeline_alert_notifier_sns" {
  count         = local.enable_pipeline_notifier ? 1 : 0
  statement_id  = "AllowExecutionFromPipelineAlerts"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_alert_notifier[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.pipeline_alerts[0].arn
}

resource "aws_sns_topic_subscription" "pipeline_alert_notifier" {
  count     = local.enable_pipeline_notifier ? 1 : 0
  topic_arn = aws_sns_topic.pipeline_alerts[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.pipeline_alert_notifier[0].arn

  depends_on = [aws_lambda_permission.pipeline_alert_notifier_sns]
}

///////////////////////////////////////
// Dashboard
///////////////////////////////////////

locals {
  dashboard_lambda_metrics = {
    for stage, lambda in local.monitored_lambdas : stage => [
      ["AWS/Lambda", "Invocations", "FunctionName", lambda.function_name, { stat = "Sum", label = "Invocations" }],
      ["AWS/Lambda", "Errors", "FunctionName", lambda.function_name, { stat = "Sum", label = "Errors" }],
      ["AWS/Lambda", "Throttles", "FunctionName", lambda.function_name, { stat = "Sum", label = "Throttles" }],
      [local.health_metric_namespace, "${title(stage)}LogErrors", { stat = "Sum", label = "Log errors" }],
    ]
  }

  dashboard_stage_widgets = [
    for index, stage in keys(local.monitored_lambdas) : {
      type   = "metric"
      x      = (index % 2) * 12
      y      = 15 + floor(index / 2) * 6
      width  = 6
      height = 6
      properties = {
        title   = "${title(stage)}: invocations and errors"
        region  = var.deployment_region
        view    = "timeSeries"
        stacked = false
        period  = 300
        metrics = local.dashboard_lambda_metrics[stage]
      }
    }
  ]

  dashboard_duration_widgets = [
    for index, stage in keys(local.monitored_lambdas) : {
      type   = "metric"
      x      = (index % 2) * 12 + 6
      y      = 15 + floor(index / 2) * 6
      width  = 6
      height = 6
      properties = {
        title   = "${title(stage)}: duration (ms)"
        region  = var.deployment_region
        view    = "timeSeries"
        stacked = false
        period  = 300
        metrics = [
          ["AWS/Lambda", "Duration", "FunctionName", local.monitored_lambdas[stage].function_name, { stat = "Maximum", label = "Maximum" }],
          ["AWS/Lambda", "Duration", "FunctionName", local.monitored_lambdas[stage].function_name, { stat = "Average", label = "Average" }],
        ]
        annotations = {
          horizontal = [{ label = "timeout", value = local.monitored_lambdas[stage].timeout * 1000 }]
        }
      }
    }
  ]

  dashboard_widgets = concat(
    [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "## ${terraform.workspace} pipeline\nLand → sort → notify → process → record. Metrics in `${local.health_metric_namespace}`; alarms notify `${local.health_prefix}-alerts`. See docs/user-guide/pipeline-health.rst."
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 2
        width  = 24
        height = 5
        properties = {
          title  = "Alarm states"
          alarms = local.enable_pipeline_alarms ? [for name in local.pipeline_alarm_names : "arn:aws:cloudwatch:${var.deployment_region}:${data.aws_caller_identity.current.account_id}:alarm:${name}"] : []
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 6
        height = 8
        properties = {
          title   = "Land: incoming bucket"
          region  = var.deployment_region
          view    = "timeSeries"
          stacked = false
          period  = local.reconciliation_period
          metrics = [
            [local.health_metric_namespace, "IncomingObjectsInWindow", { stat = "Maximum", label = "Landed in window" }],
            [local.health_metric_namespace, "UnsortedIncomingObjects", { stat = "Maximum", label = "Unsorted (alarm)" }],
            [local.health_metric_namespace, "IncomingBacklogObjects", { stat = "Maximum", label = "Backlog (older than window)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 7
        width  = 6
        height = 8
        properties = {
          title   = "Notify: topic deliveries"
          region  = var.deployment_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = concat(
            [for bucket in local.instrument_bucket_names : ["AWS/SNS", "NumberOfNotificationsDelivered", "TopicName", "${local.environment_short_name}${bucket}-sns-topic", { stat = "Sum", label = "${local.instrument_by_bucket[bucket]} delivered" }]],
            [for bucket in local.instrument_bucket_names : ["AWS/SNS", "NumberOfNotificationsFailed", "TopicName", "${local.environment_short_name}${bucket}-sns-topic", { stat = "Sum", label = "${local.instrument_by_bucket[bucket]} failed" }]],
          )
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 6
        height = 8
        properties = {
          title   = "Notify: queue age (s)"
          region  = var.deployment_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [for bucket in local.instrument_bucket_names : ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", "${local.environment_short_name}${bucket}-sqs-queue", { stat = "Maximum", label = local.instrument_by_bucket[bucket] }]]
          annotations = {
            horizontal = [{ label = "alarm", value = var.pipeline_sqs_oldest_message_age_threshold_seconds }]
          }
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 7
        width  = 6
        height = 8
        properties = {
          title   = "Record: reconciliation"
          region  = var.deployment_region
          view    = "timeSeries"
          stacked = false
          period  = local.reconciliation_period
          metrics = [
            [local.health_metric_namespace, "ReconciledObjects", { stat = "Maximum", label = "Objects checked" }],
            [local.health_metric_namespace, "MissingMetaTrackerRows", { stat = "Maximum", label = "Missing MetaTracker rows (alarm)" }],
            [local.health_metric_namespace, "MissingTimestreamRecords", { stat = "Maximum", label = "Missing Timestream records (alarm)" }],
            [local.health_metric_namespace, "FailedProcessingFiles", { stat = "Maximum", label = "Failed status rows" }],
            [local.health_metric_namespace, "ReconciliationCheckErrors", { stat = "Maximum", label = "Check errors (alarm)" }],
          ]
        }
      },
    ],
    local.dashboard_stage_widgets,
    local.dashboard_duration_widgets,
  )
}

resource "aws_cloudwatch_dashboard" "pipeline" {
  count          = local.enable_pipeline_alarms ? 1 : 0
  dashboard_name = local.health_prefix
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
