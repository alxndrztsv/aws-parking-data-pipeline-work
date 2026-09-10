resource "aws_dynamodb_table" "ingestion_state" {
  name         = "${local.prefix}-ingestion-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run_id"
  range_key    = "city_code"

  attribute {
    name = "run_id"
    type = "S"
  }

  attribute {
    name = "city_code"
    type = "S"
  }
}