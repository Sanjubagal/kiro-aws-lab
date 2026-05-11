###############################################################
# MONITORING & OBSERVABILITY
# Free: CloudWatch 10 metrics, 10 alarms, 5GB logs (always free)
#       X-Ray 100k traces/mo (always free)
#       CloudTrail 1 trail (always free)
###############################################################

# --- CLOUDWATCH LOG GROUPS ---

resource "aws_cloudwatch_log_group" "app" {
  name              = "/kiro-lab/app"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/kiro-lab/web"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "lambda_processor" {
  name              = "/aws/lambda/${local.name}-processor"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "lambda_s3" {
  name              = "/aws/lambda/${local.name}-s3-processor"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "lambda_scheduler" {
  name              = "/aws/lambda/${local.name}-scheduler"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "rds" {
  name              = "/aws/rds/instance/${local.name}-mysql/error"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/${local.name}"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = 30
  tags              = local.tags
}

# --- CLOUDWATCH ALARMS (Free: 10 alarms) ---

resource "aws_cloudwatch_metric_alarm" "ec2_web_cpu" {
  alarm_name          = "${local.name}-web-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Web server CPU > 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { InstanceId = aws_instance.web.id }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "ec2_web_status" {
  alarm_name          = "${local.name}-web-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Web server status check failed"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { InstanceId = aws_instance.web.id }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU > 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${local.name}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2000000000 # 2GB
  alarm_description   = "RDS free storage < 2GB"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda errors > 5 in 5 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { FunctionName = aws_lambda_function.processor.function_name }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "sqs_dlq_depth" {
  alarm_name          = "${local.name}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages in DLQ - processing failures"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { QueueName = aws_sqs_queue.processor_dlq.name }
  tags                = local.tags
}

# --- CLOUDWATCH DASHBOARD (Free) ---

resource "aws_cloudwatch_dashboard" "lab" {
  dashboard_name = "${local.name}-dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6
        properties = {
          title  = "EC2 CPU Utilization"
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web.id, { label = "Web Server" }],
                     ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id, { label = "App Server" }]]
          period = 300, stat = "Average", view = "timeSeries"
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 8, height = 6
        properties = {
          title  = "RDS Metrics"
          metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.mysql.identifier],
                     ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.mysql.identifier]]
          period = 300, stat = "Average", view = "timeSeries"
        }
      },
      {
        type = "metric", x = 16, y = 0, width = 8, height = 6
        properties = {
          title  = "Lambda Invocations & Errors"
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.processor.function_name],
                     ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.processor.function_name]]
          period = 300, stat = "Sum", view = "timeSeries"
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title  = "SQS Queue Depth"
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.processor.name],
                     ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.processor_dlq.name, { label = "DLQ" }]]
          period = 300, stat = "Average", view = "timeSeries"
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title  = "DynamoDB Consumed Capacity"
          metrics = [["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.users.name],
                     ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.users.name]]
          period = 300, stat = "Sum", view = "timeSeries"
        }
      },
      {
        type = "alarm", x = 16, y = 6, width = 8, height = 6
        properties = {
          title  = "Alarm Status"
          alarms = [
            aws_cloudwatch_metric_alarm.ec2_web_cpu.arn,
            aws_cloudwatch_metric_alarm.ec2_web_status.arn,
            aws_cloudwatch_metric_alarm.rds_cpu.arn,
            aws_cloudwatch_metric_alarm.rds_storage.arn,
            aws_cloudwatch_metric_alarm.lambda_errors.arn,
            aws_cloudwatch_metric_alarm.sqs_dlq_depth.arn
          ]
        }
      }
    ]
  })
}

# --- CLOUDTRAIL (Free: 1 trail, management events) ---

resource "aws_cloudtrail" "lab" {
  name                          = "${local.name}-trail"
  s3_bucket_name                = aws_s3_bucket.logs.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.assets.arn}/"]
    }
    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"]
    }
  }

  tags = merge(local.tags, { Name = "${local.name}-trail" })
  depends_on = [aws_s3_bucket_policy.logs_cloudtrail]
}
