# Create IAM Role for Lambda
resource "aws_iam_role" "lambda_ingest_data_role" {
  name = "${local.prefix}-lambda-ingest-data-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_ingest_data_policy" {
  name = "${local.prefix}-lambda-ingest-data-policy"
  role = aws_iam_role.lambda_ingest_data_role.id
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
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.data_ingestion_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.ingestion_state.arn
      },
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.api_password.arn,
          aws_ssm_parameter.api_login.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.layers["bronze"].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

# --- Ingest data Lambda ---
# Package ingest_data.py into .zip file
data "archive_file" "lambda_ingest_data_zip" {
  type        = "zip"
  source_file = "../lambda_functions/ingest_data.py"
  output_path = "../lambda_functions/ingest_data.zip"
}

# requests is not bundled with the Lambda Python runtime, ship it as a layer
resource "aws_lambda_layer_version" "requests_layer" {
  filename            = "../lambda_functions/requests_layer.zip"
  layer_name          = "${local.prefix}-requests"
  compatible_runtimes = ["python3.11"]
  source_code_hash    = filebase64sha256("../lambda_functions/requests_layer.zip")
}

# Create Lambda function
resource "aws_lambda_function" "ingest_data" {
  filename         = data.archive_file.lambda_ingest_data_zip.output_path
  function_name    = "${local.prefix}-ingest-data"
  role             = aws_iam_role.lambda_ingest_data_role.arn
  handler          = "ingest_data.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_ingest_data_zip.output_base64sha256
  timeout          = 60
  layers           = [aws_lambda_layer_version.requests_layer.arn]

  environment {
    variables = {
      QUEUE_URL             = aws_sqs_queue.data_ingestion_queue.url
      TABLE_NAME            = aws_dynamodb_table.ingestion_state.name
      BRONZE_BUCKET         = aws_s3_bucket.layers["bronze"].id
      API_LOGIN_SSM_PATH    = aws_ssm_parameter.api_login.name
      API_PASSWORD_SSM_PATH = aws_ssm_parameter.api_password.name
      API_URL               = var.api_url
      MAX_RECEIVE_COUNT     = var.max_receive_count
    }
  }
}

# --- Outputs ---
output "lambda_ingest_data_name" {
  value = aws_lambda_function.ingest_data.function_name
}