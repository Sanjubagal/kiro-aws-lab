###############################################################
# MESSAGING
# Free: SNS 1M publishes/mo (always free)
#       SQS 1M requests/mo (always free)
###############################################################

# SNS Topics
resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = merge(local.tags, { Name = "${local.name}-alerts" })
}

resource "aws_sns_topic" "events" {
  name = "${local.name}-events"
  tags = merge(local.tags, { Name = "${local.name}-events" })
}

resource "aws_sns_topic" "notifications" {
  name = "${local.name}-notifications"
  tags = merge(local.tags, { Name = "${local.name}-notifications" })
}

# SNS Email Subscription
resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# SNS -> SQS Subscription
resource "aws_sns_topic_subscription" "events_to_sqs" {
  topic_arn = aws_sns_topic.events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.processor.arn
}

# SQS Queues
resource "aws_sqs_queue" "processor" {
  name                       = "${local.name}-processor"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20 # Long polling
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.processor_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.tags, { Name = "${local.name}-processor" })
}

# Dead Letter Queue
resource "aws_sqs_queue" "processor_dlq" {
  name                      = "${local.name}-processor-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = merge(local.tags, { Name = "${local.name}-processor-dlq" })
}

# S3 Events Queue
resource "aws_sqs_queue" "s3_events" {
  name                      = "${local.name}-s3-events"
  message_retention_seconds = 86400
  tags                      = merge(local.tags, { Name = "${local.name}-s3-events" })
}

# SQS Policy to allow S3 to send messages
resource "aws_sqs_queue_policy" "s3_events" {
  queue_url = aws_sqs_queue.s3_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.s3_events.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.assets.arn }
      }
    }]
  })
}

# SQS Policy to allow SNS to send messages
resource "aws_sqs_queue_policy" "processor" {
  queue_url = aws_sqs_queue.processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.processor.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_sns_topic.events.arn }
      }
    }]
  })
}
