terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

resource "aws_s3_bucket" "receipts" {
  bucket = "receipt-processor-nevenspooner"
}

resource "aws_sqs_queue" "receipts_dlq" {
  name                      = "receipt-processor-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "receipts_queue" {
  name                       = "receipt-processor-queue"
  visibility_timeout_seconds = 180

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.receipts_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_dynamodb_table" "receipts" {
  name         = "receipt-processor-results"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "receipt_id"

  attribute {
    name = "receipt_id"
    type = "S"
  }
}

resource "aws_sqs_queue_policy" "allow_s3" {
  queue_url = aws_sqs_queue.receipts_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.receipts_queue.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_s3_bucket.receipts.arn }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.receipts.id

  queue {
    queue_arn = aws_sqs_queue.receipts_queue.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.allow_s3]
}
