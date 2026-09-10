# Create IAM Role for Lambda
resource "aws_iam_role" "lambda_prepare_ingestion_role" {
  name = "${local.prefix}-lambda-prepare-ingestion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_prepare_ingestion_policy" {
  name = "${local.prefix}-lambda-prepare-ingestion-policy"
  role = aws_iam_role.lambda_prepare_ingestion_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
          "sqs:SendMessage"
        ]
        Resource = [aws_sqs_queue.data_ingestion_queue.arn, aws_sqs_queue.data_ingestion_dlq.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Scan",
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.ingestion_state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.layers["bronze"].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.layers["gold"].arn}/manifests/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.layers["scripts"].arn}/${aws_s3_object.parks_reference.key}"
      }
    ]
  })
}

# --- Prepare ingestion Lambda ---
# Package prepare_ingestion.py into .zip file
data "archive_file" "lambda_prepare_ingestion_zip" {
  type        = "zip"
  source_file = "../lambda_functions/prepare_ingestion.py"
  output_path = "../lambda_functions/prepare_ingestion.zip"
}

# Create Lambda function
resource "aws_lambda_function" "prepare_ingestion" {
  filename         = data.archive_file.lambda_prepare_ingestion_zip.output_path
  function_name    = "${local.prefix}-prepare-ingestion"
  role             = aws_iam_role.lambda_prepare_ingestion_role.arn
  handler          = "prepare_ingestion.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_prepare_ingestion_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      QUEUE_URL        = aws_sqs_queue.data_ingestion_queue.url
      TABLE_NAME       = aws_dynamodb_table.ingestion_state.name
      REFERENCE_BUCKET = aws_s3_bucket.layers["scripts"].id
      REFERENCE_KEY    = aws_s3_object.parks_reference.key
    }
  }
}

output "lambda_prepare_ingestion_name" {
  value = aws_lambda_function.prepare_ingestion.function_name
}