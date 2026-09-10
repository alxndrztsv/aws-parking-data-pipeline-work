# Create IAM Role for Lambda
resource "aws_iam_role" "lambda_check_ingestion_role" {
  name = "${local.prefix}-lambda-check-ingestion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_check_ingestion_policy" {
  name = "${local.prefix}-lambda-check-ingestion-policy"
  role = aws_iam_role.lambda_check_ingestion_role.id
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
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.ingestion_state.arn
      }
    ]
  })
}

# --- Prepare ingestion Lambda ---
# Package check_ingestion.py into .zip file
data "archive_file" "lambda_check_ingestion_zip" {
  type        = "zip"
  source_file = "../lambda_functions/check_ingestion.py"
  output_path = "../lambda_functions/check_ingestion.zip"
}

# Create Lambda function
resource "aws_lambda_function" "check_ingestion" {
  filename         = data.archive_file.lambda_check_ingestion_zip.output_path
  function_name    = "${local.prefix}-check-ingestion"
  role             = aws_iam_role.lambda_check_ingestion_role.arn
  handler          = "check_ingestion.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_check_ingestion_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.ingestion_state.name
    }
  }
}

# --- Outputs ---
output "lambda_check_ingestion_name" {
  value = aws_lambda_function.check_ingestion.function_name
}