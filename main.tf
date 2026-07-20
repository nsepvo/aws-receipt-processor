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
