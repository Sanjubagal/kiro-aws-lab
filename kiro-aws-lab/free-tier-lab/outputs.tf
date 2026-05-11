###############################################################
# OUTPUTS
###############################################################

output "web_server_public_ip" {
  description = "Web server public IP (Elastic IP)"
  value       = aws_eip.web.public_ip
}

output "app_server_public_ip" {
  description = "App server public IP"
  value       = aws_instance.app.public_ip
}

output "api_gateway_url" {
  description = "API Gateway endpoint URL"
  value       = "https://${aws_api_gateway_rest_api.lab.id}.execute-api.${var.region}.amazonaws.com/lab"
}

output "rds_endpoint" {
  description = "RDS MySQL endpoint"
  value       = aws_db_instance.mysql.address
  sensitive   = true
}

output "s3_assets_bucket" {
  description = "S3 assets bucket name"
  value       = aws_s3_bucket.assets.bucket
}

output "s3_logs_bucket" {
  description = "S3 logs bucket name"
  value       = aws_s3_bucket.logs.bucket
}

output "dynamodb_users_table" {
  description = "DynamoDB users table name"
  value       = aws_dynamodb_table.users.name
}

output "dynamodb_events_table" {
  description = "DynamoDB events table name"
  value       = aws_dynamodb_table.events.name
}

output "sns_alerts_arn" {
  description = "SNS alerts topic ARN"
  value       = aws_sns_topic.alerts.arn
}

output "sqs_processor_url" {
  description = "SQS processor queue URL"
  value       = aws_sqs_queue.processor.url
}

output "lambda_processor_arn" {
  description = "Lambda processor function ARN"
  value       = aws_lambda_function.processor.arn
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.lab.dashboard_name}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.lab.id
}

output "db_secret_arn" {
  description = "Secrets Manager ARN for DB credentials"
  value       = aws_secretsmanager_secret.db_password.arn
  sensitive   = true
}

output "lab_summary" {
  description = "Summary of all lab resources"
  value = {
    vpc              = aws_vpc.lab.id
    ec2_web          = aws_instance.web.id
    ec2_app          = aws_instance.app.id
    rds_mysql        = aws_db_instance.mysql.identifier
    dynamodb_tables  = [aws_dynamodb_table.users.name, aws_dynamodb_table.events.name, aws_dynamodb_table.config.name]
    s3_buckets       = [aws_s3_bucket.assets.bucket, aws_s3_bucket.logs.bucket, aws_s3_bucket.lambda_code.bucket]
    lambda_functions = [aws_lambda_function.processor.function_name, aws_lambda_function.s3_processor.function_name, aws_lambda_function.scheduler.function_name]
    sns_topics       = [aws_sns_topic.alerts.name, aws_sns_topic.events.name, aws_sns_topic.notifications.name]
    sqs_queues       = [aws_sqs_queue.processor.name, aws_sqs_queue.processor_dlq.name, aws_sqs_queue.s3_events.name]
    api_gateway      = aws_api_gateway_rest_api.lab.name
    cloudtrail       = aws_cloudtrail.lab.name
  }
}
