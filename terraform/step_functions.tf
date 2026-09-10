# Create IAM Role for Step Functions
resource "aws_iam_role" "sfn_role" {
  name = "${local.prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "sfn_policy" {
  name = "${local.prefix}-sfn-policy"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetJob",
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns",
          "glue:StartCrawler",
          "glue:GetCrawler",
          "glue:GetCrawlerMetrics",
          "glue:BatchStopJobRun",
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_glue_job.bronze_to_silver.arn,
          aws_glue_crawler.silver_crawler.arn,
          aws_glue_job.silver_to_gold.arn,
          aws_lambda_function.email_report.arn,
          aws_lambda_function.prepare_ingestion.arn,
          aws_lambda_function.ingest_data.arn,
          aws_lambda_function.check_ingestion.arn,
          aws_lambda_function.generate_manifest.arn
        ]
      },
      # Allow publishing to SNS for pipeline failures
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.pipeline_alerts.arn
      }
    ]
  })
}

# State Functions State Machine definition
resource "aws_sfn_state_machine" "pipeline_orchestrator" {
  name     = "${local.prefix}-pipeline-orchestrator"
  role_arn = aws_iam_role.sfn_role.arn

  definition = jsonencode({
    Comment        = "Full pipeline: Ingest -> Bronze -> Silver -> SilverCrawler -> Gold -> Email"
    TimeoutSeconds = 7200 # 2 hours max for entire execution
    StartAt        = "GenerateRunId"

    States = {
      # --- 0 step: Generate run_id ---
      GenerateRunId = {
        Type = "Pass"
        Parameters = {
          "run_id.$" : "$$.Execution.Name"
        }
        Next = "PrepareIngestion"
      }
      # --- 1 step: Ingestion ---
      PrepareIngestion = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.prepare_ingestion.arn
          Payload = {
            "run_id.$" : "$.run_id"
          }
        }
        ResultSelector = {
          "run_id.$" : "$.Payload.run_id"
        }
        ResultPath = "$.ingestion_config"
        Retry = [
          {
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]
        Next = "WaitBeforeIngestion"
      }
      # --- 1.1 step: Wait ---
      # Wait 60 second because of API rate limit
      WaitBeforeIngestion = {
        Type    = "Wait"
        Seconds = 60
        Next    = "ProcessOneCity"
      }
      # --- 1.2 step: Process park ---
      # Process one city from SQS
      ProcessOneCity = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.ingest_data.arn
          Payload = {
            "run_id.$" : "$.ingestion_config.run_id"
          }
        }
        ResultPath     = null
        TimeoutSeconds = 90
        Retry = [
          {
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException"]
            IntervalSeconds = 10
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]
        Next = "CheckIngestion"
      }
      # --- 1.3 step: Check ingestion status ---
      # Check DynamoDB for cities left
      CheckIngestion = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.check_ingestion.arn
          Payload = {
            "run_id.$" : "$.ingestion_config.run_id"
          }
        }
        ResultSelector = {
          "is_complete.$" : "$.Payload.is_complete"
          "total.$" : "$.Payload.total"
          "pending.$" : "$.Payload.pending"
          "success.$" : "$.Payload.success"
          "failed.$" : "$.Payload.failed"
        }
        ResultPath = "$.ingestion_status"
        Retry = [
          {
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 10
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]
        Next = "IsIngestionComplete"
      }
      # --- 1.4 step: Check if ingestion is complete ---
      # Loop or go next
      IsIngestionComplete = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.ingestion_status.is_complete"
            BooleanEquals = true
            Next          = "GenerateManifest"
          }
        ]
        Default = "WaitBeforeIngestion"
      }
      # --- 2 step: Generate manifest ---
      # Create manifest
      GenerateManifest = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.generate_manifest.arn
          Payload = {
            "run_id.$" : "$.ingestion_config.run_id"
          }
        }
        ResultPath = null
        Retry = [
          {
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 30
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]
        Next = "BronzeToSilver"
      }
      # --- 3 step: Bronze to Silver Glue job ---
      BronzeToSilver = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"

        Parameters = {
          JobName = aws_glue_job.bronze_to_silver.name
          Arguments = {
            "--run_id.$" : "$.ingestion_config.run_id"
          }
        }

        ResultPath = null # discard Glue response

        Retry = [
          {
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 60
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]

        Next = "SilverCrawlerStart"
      }

      # --- 4 step: Silver crawler ---
      # 1. Start the crawler
      SilverCrawlerStart = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"

        Parameters = {
          Name = aws_glue_crawler.silver_crawler.name
        }

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]

        Next = "SilverCrawlerWait"
      }

      # 2. Wait for a short period before checking status (prevents API throttling)
      SilverCrawlerWait = {
        Type    = "Wait"
        Seconds = 30
        Next    = "SilverCrawlerCheck"
      }

      # 3. Check the current state of the crawler
      SilverCrawlerCheck = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"

        Parameters = {
          Name = aws_glue_crawler.silver_crawler.name
        }

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]

        Next = "SilverCrawlerReady"
      }

      # 4. Evaluate if the crawler has finished (state returns to "READY" when done)
      SilverCrawlerReady = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Crawler.State"
            StringEquals = "READY"
            Next         = "SilverToGold"
          }
        ]
        # If it's still "RUNNING" or "STOPPING", loop back to wait
        Default = "SilverCrawlerWait"
      }
      # --- 5 step: Silver to Gold Glue job ---
      SilverToGold = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"

        Parameters = {
          JobName = aws_glue_job.silver_to_gold.name
        }

        ResultPath = null # discard Glue response

        Retry = [
          {
            ErrorEquals     = ["States.ALL"]
            IntervalSeconds = 60
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]

        Next = "SendEmailReport"
      }

      # --- 6 step: Send email lambda function ---
      SendEmailReport = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"

        Parameters = {
          FunctionName = aws_lambda_function.email_report.arn
        }

        Retry = [
          {
            ErrorEquals = ["States.ALL"]
            MaxAttempts = 2
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailure"
          }
        ]

        End = true
      }

      # Handle pipeline failure
      PipelineFailure = {
        Type  = "Fail"
        Error = "PipelineExecutionFailed"
        Cause = "Check CloudWatch logs for details."
      }
    }
  })
}

output "sfn_arn" {
  description = "ARN of the Step Functions state machine"
  value       = aws_sfn_state_machine.pipeline_orchestrator.arn
}