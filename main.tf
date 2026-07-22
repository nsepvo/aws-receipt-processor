terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "receipt-processor-tfstate-nevenspooner"
    key          = "receipt-processor/terraform.tfstate"
    region       = "ap-southeast-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

# ---------- Storage ----------

resource "aws_s3_bucket" "receipts" {
  bucket = "receipt-processor-nevenspooner"
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

# ---------- Queues ----------

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

# ---------- Processing Lambda ----------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda/lambda.zip"
}

resource "aws_iam_role" "processor_role" {
  name = "receipt-processor-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "processor_policy" {
  name = "receipt-processor-lambda-policy"
  role = aws_iam_role.processor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.receipts_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.receipts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "textract:AnalyzeExpense"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.receipts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "processor" {
  function_name    = "receipt-processor"
  role             = aws_iam_role.processor_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.receipts_queue.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1
}

# ---------- Query Lambda ----------

data "archive_file" "query_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda-query/lambda_function.py"
  output_path = "${path.module}/lambda-query/query.zip"
}

resource "aws_iam_role" "query_role" {
  name = "receipt-processor-query-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "query_policy" {
  name = "receipt-processor-query-policy"
  role = aws_iam_role.query_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "dynamodb:Scan"
        Resource = aws_dynamodb_table.receipts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "query" {
  function_name    = "receipt-processor-query"
  role             = aws_iam_role.query_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.receipts.name
    }
  }
}

# ---------- API Gateway ----------

resource "aws_apigatewayv2_api" "receipts_api" {
  name          = "receipt-processor-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "query_integration" {
  api_id                 = aws_apigatewayv2_api.receipts_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.query.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_receipts" {
  api_id    = aws_apigatewayv2_api.receipts_api.id
  route_key = "GET /receipts"
  target    = "integrations/${aws_apigatewayv2_integration.query_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.receipts_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.receipts_api.execution_arn}/*/*"
}

output "api_url" {
  value = "${aws_apigatewayv2_stage.default.invoke_url}/receipts"
}

# ---------- Frontend ----------

resource "aws_s3_bucket" "frontend" {
  bucket = "receipt-processor-site-nevenspooner"
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend_public" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"

  content = templatefile("${path.module}/frontend/index.html.tftpl", {
    api_url = "${aws_apigatewayv2_stage.default.invoke_url}/receipts"
  })

  etag = md5(templatefile("${path.module}/frontend/index.html.tftpl", {
    api_url = "${aws_apigatewayv2_stage.default.invoke_url}/receipts"
  }))
}

output "site_url" {
  value = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
}

# ---------- Alerting ----------

resource "aws_sns_topic" "alerts" {
  name = "receipt-processor-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "nevenspooner03@example.com"
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "receipt-processor-dlq-not-empty"
  alarm_description   = "A receipt failed processing 3 times and landed in the DLQ"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.receipts_dlq.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
