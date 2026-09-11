# IAM role assumed by AWS Glue
resource "aws_iam_role" "glue_service_role" {
  name = "${local.prefix}-glue-role"
  # Trust policy allowing Glue to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com" # service that will use this role
        }
      }
    ]
  })
}

# Allow Glue to read/write to s3 buckets
resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${local.prefix}-glue-s3-policy"
  role = aws_iam_role.glue_service_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",        # to overwrite files
          "s3:DeleteObjectVersion", # to overwrite files
          "s3:ListBucket",
        ]
        Resource = flatten([
          for k, b in aws_s3_bucket.layers : [b.arn, "${b.arn}/*"]
        ])
      }
    ]
  })
}

# Attach managed AWSGlueServiceRole policy for CloudWatch logs and Glue APIs
resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  role       = aws_iam_role.glue_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# -- Glue Data Catalog ---
resource "aws_glue_catalog_database" "parking_db" {
  name = "${local.prefix}-parking-db"
}

resource "aws_glue_crawler" "silver_crawler" {
  name          = "${local.prefix}-silver-crawler"
  role          = aws_iam_role.glue_service_role.arn
  database_name = aws_glue_catalog_database.parking_db.name
  schedule      = null

  s3_target {
    path = "s3://${aws_s3_bucket.layers["silver"].id}/processed/"
  }
}

# --- BronzeToSilver ---
# Create AWS Glue ETL Job
resource "aws_glue_job" "bronze_to_silver" {
  name = "${local.prefix}-bronze-to-silver"
  # Specify role created earlier
  role_arn = aws_iam_role.glue_service_role.arn
  # Glue ETL script stored in S3
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.layers["scripts"].id}/bronze_to_silver.py"
    python_version  = "3"
  }

  # Arguments to pass to python script via getResolvedOptions
  default_arguments = {
    "--job-language"                     = "python"
    "--source_bucket"                    = aws_s3_bucket.layers["bronze"].id
    "--target_bucket"                    = aws_s3_bucket.layers["silver"].id
    "--TempDir"                          = "s3://${aws_s3_bucket.layers["scripts"].id}/temp/"
    "--job-bookmark-option"              = "job-bookmark-disable" # just for static synthetic data
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }

  # Glue version and compute capacity
  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X" # smallest general-purpose Glue worker

  execution_property {
    max_concurrent_runs = 1
  }

  # Script should be uploaded before creating the Glue job
  depends_on = [aws_s3_object.glue_scripts["bronze_to_silver.py"]]
}

# --- SilverToGold ---
# Create AWS Glue ETL Job
resource "aws_glue_job" "silver_to_gold" {
  name     = "${local.prefix}-silver-to-gold"
  role_arn = aws_iam_role.glue_service_role.arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.layers["scripts"].id}/silver_to_gold.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--source_bucket"                    = aws_s3_bucket.layers["silver"].id
    "--target_bucket"                    = aws_s3_bucket.layers["gold"].id
    "--reference_bucket"                 = aws_s3_bucket.layers["scripts"].id
    "--reference_key"                    = "reference/parks.csv"
    "--TempDir"                          = "s3://${aws_s3_bucket.layers["scripts"].id}/temp/"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }

  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [aws_s3_object.glue_scripts["silver_to_gold.py"]]
}

# --- Outputs ---
output "glue_role_arn" {
  description = "ARN of the IAM role used by AWS Glue jobs"
  value       = aws_iam_role.glue_service_role.arn
}

output "glue_job_silver_name" {
  description = "Name of the bronze-to-silver Glue job"
  value       = aws_glue_job.bronze_to_silver.name
}

output "glue_job_gold_name" {
  description = "Name of the silver-to-gold Glue job"
  value       = aws_glue_job.silver_to_gold.name
}