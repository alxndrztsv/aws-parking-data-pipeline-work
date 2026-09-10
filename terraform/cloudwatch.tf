# ===== Alarms =====
# --- Step functions alarms ---
# Alarm if execution failed
resource "aws_cloudwatch_metric_alarm" "sfn_execution_failed" {
  alarm_name          = "${local.prefix}-sfn-execution-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Step functions execution failed"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline_orchestrator.arn
  }
}

# Alarm if execution timed out
resource "aws_cloudwatch_metric_alarm" "sfn_execution_timeout" {
  alarm_name          = "${local.prefix}-sfn-execution-timeout"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionTimedOut"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Step functions execution timed out"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline_orchestrator.arn
  }
}

# Alarm if execution longer than 60 minutes
resource "aws_cloudwatch_metric_alarm" "sfn_execution_duration" {
  alarm_name          = "${local.prefix}-sfn-execution-duration"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionTime"
  namespace           = "AWS/States"
  period              = 3600
  statistic           = "Maximum"
  threshold           = 3600000
  alarm_description   = "Pipeline execution exceeded 60 minutes"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline_orchestrator.arn
  }
}

# --- Lambda alarms ---
# Lambda throttle alarm
resource "aws_cloudwatch_metric_alarm" "ingest_lambda_throttle" {
  alarm_name          = "${local.prefix}-lambda-ingest-data-throttled"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Ingest Lambda is being throttled"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.ingest_data.function_name
  }
}

# --- SQS DLQ alarms ---
# Any message received in DLQ alarm
resource "aws_cloudwatch_metric_alarm" "sqs_dlq_message" {
  alarm_name          = "${local.prefix}-sqs-dlq-message"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "Messages detected in DLQ"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.data_ingestion_dlq.name
  }
}

# ===== Dashboard =====
resource "aws_cloudwatch_dashboard" "pipeline_dashboard" {
  dashboard_name = "${local.prefix}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions Execution"
          region = var.aws_region
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.pipeline_orchestrator.arn],
            [".", "ExecutionsSucceeded", ".", "."],
            [".", "ExecutionsFailed", ".", "."]
          ]
          period = 86400
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Errors & Throttles"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.ingest_data.function_name],
            [".", "Throttles", ".", "."],
            [".", "Errors", "FunctionName", aws_lambda_function.prepare_ingestion.function_name],
            [".", "Errors", "FunctionName", aws_lambda_function.check_ingestion.function_name],
            [".", "Errors", "FunctionName", aws_lambda_function.generate_manifest.function_name],
            [".", "Errors", "FunctionName", aws_lambda_function.email_report.function_name]
          ]
          period = 3600
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "SQS Queue Health"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.data_ingestion_queue.name],
            [".", "ApproximateAgeOfOldestMessage", ".", "."],
            [".", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.data_ingestion_dlq.name]
          ]
          period = 3600
          stat   = "Maximum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Execution Duration (ms)"
          region = var.aws_region
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", aws_sfn_state_machine.pipeline_orchestrator.arn]
          ]
          period = 86400
          stat   = "Maximum"
          view   = "timeSeries"
        }
      }
    ]
  })
}

# ===== Logs =====
# Retention for logs
resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/states/${local.prefix}-pipeline"
  retention_in_days = 30
}

# For Lambda create explicit log groups
resource "aws_cloudwatch_log_group" "ingest_data" {
  name              = "/aws/lambda/${local.prefix}-ingest-data"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "prepare_ingestion" {
  name              = "/aws/lambda/${local.prefix}-prepare-ingestion"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "check_ingestion" {
  name              = "/aws/lambda/${local.prefix}-check-ingestion"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "generate_manifest" {
  name              = "/aws/lambda/${local.prefix}-generate-manifest"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "email_report" {
  name              = "/aws/lambda/${local.prefix}-email-report"
  retention_in_days = 30
}