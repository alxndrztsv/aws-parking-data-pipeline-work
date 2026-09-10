resource "aws_s3_object" "parks_reference" {
  bucket = aws_s3_bucket.layers["scripts"].id
  key    = "reference/parks.csv"
  source = "../reference_data/parks.csv"
  etag   = filemd5("../reference_data/parks.csv")
}

# Glue ETL scripts must live in S3 before the Glue jobs can reference them
resource "aws_s3_object" "glue_scripts" {
  for_each = {
    "bronze_to_silver.py" = "../glue_scripts/bronze_to_silver.py"
    "silver_to_gold.py"   = "../glue_scripts/silver_to_gold.py"
  }

  bucket = aws_s3_bucket.layers["scripts"].id
  key    = each.key
  source = each.value
  etag   = filemd5(each.value)
}