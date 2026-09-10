resource "aws_sqs_queue" "data_ingestion_dlq" {
  name                      = "${local.prefix}-data-ingestion-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "data_ingestion_queue" {
  name                       = "${local.prefix}-data-ingestion-queue"
  visibility_timeout_seconds = 90     # default visibility timeout
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.data_ingestion_dlq.arn
    maxReceiveCount     = tonumber(var.max_receive_count) # 1 initial + 3 retries = moves to DLQ on 4th fail
  })
}