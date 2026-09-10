data "aws_caller_identity" "current" {}

# Create IAM Role for Lambda
resource "aws_iam_role" "lambda_email_report_role" {
  name = "${local.prefix}-lambda-email-report-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Attach policies for CloudWatch Logs, S3 read, and SES send
resource "aws_iam_role_policy" "lambda_email_report_policy" {
  name = "${local.prefix}-lambda-email-report-policy"
  role = aws_iam_role.lambda_email_report_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow CloudWatch logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-email-report:*"
      },
      # Allow access to S3
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.layers["gold"].arn,
          "${aws_s3_bucket.layers["gold"].arn}/*"
        ]
      },
      # Allow sending email via SES
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${var.sender_email}" # to any email address verified
      }
    ]
  })
}

# Package Lambda code into .zip file
data "archive_file" "lambda_email_report_zip" {
  type        = "zip"
  source_file = "../lambda_functions/email_report.py"
  output_path = "../lambda_functions/email_report.zip"
}

# Create Lambda function
resource "aws_lambda_function" "email_report" {
  filename         = data.archive_file.lambda_email_report_zip.output_path
  function_name    = "${local.prefix}-email-report"
  role             = aws_iam_role.lambda_email_report_role.arn
  handler          = "email_report.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_email_report_zip.output_base64sha256

  environment {
    variables = {
      GOLD_BUCKET_NAME = aws_s3_bucket.layers["gold"].id
      SENDER_EMAIL     = var.sender_email
      RECIPIENT_EMAIL  = var.recipient_email
    }
  }

  timeout = 60
}

output "lambda_email_report_name" {
  value = aws_lambda_function.email_report.function_name
}