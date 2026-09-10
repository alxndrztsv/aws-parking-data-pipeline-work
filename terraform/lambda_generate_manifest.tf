# Create IAM Role for Lambda
resource "aws_iam_role" "lambda_generate_manifest_role" {
  name = "${local.prefix}-lambda-generate-manifest-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_generate_manifest_policy" {
  name = "${local.prefix}-lambda-generate-manifest-policy"
  role = aws_iam_role.lambda_generate_manifest_role.id
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
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.layers["gold"].arn}/manifests/*"
      }
    ]
  })
}

# --- Prepare ingestion Lambda ---
# Package generate_manifest.py into .zip file
data "archive_file" "lambda_generate_manifest_zip" {
  type        = "zip"
  source_file = "../lambda_functions/generate_manifest.py"
  output_path = "../lambda_functions/generate_manifest.zip"
}

# Create Lambda function
resource "aws_lambda_function" "generate_manifest" {
  filename         = data.archive_file.lambda_generate_manifest_zip.output_path
  function_name    = "${local.prefix}-generate-manifest"
  role             = aws_iam_role.lambda_generate_manifest_role.arn
  handler          = "generate_manifest.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_generate_manifest_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      TABLE_NAME      = aws_dynamodb_table.ingestion_state.name
      MANIFEST_BUCKET = aws_s3_bucket.layers["gold"].id
    }
  }
}

# --- Outputs ---
output "lambda_generate_manifest_name" {
  value = aws_lambda_function.generate_manifest.function_name
}