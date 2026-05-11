###############################################################
# SERVERLESS
# Free: Lambda 1M requests/mo + 400,000 GB-seconds (always free)
#       API Gateway 1M calls/mo (12 months free)
###############################################################

# Lambda function zip
data "archive_file" "lambda_processor" {
  type        = "zip"
  output_path = "/tmp/lambda_processor.zip"
  source {
    content  = <<-PYEOF
import json
import boto3
import os
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb', region_name=os.environ.get('AWS_REGION', 'ap-south-1'))
sns = boto3.client('sns', region_name=os.environ.get('AWS_REGION', 'ap-south-1'))

def handler(event, context):
    logger.info(f"Event received: {json.dumps(event)}")

    table = dynamodb.Table(os.environ.get('EVENTS_TABLE', ''))
    event_id = context.aws_request_id

    # Store event in DynamoDB
    table.put_item(Item={
        'eventId': event_id,
        'timestamp': datetime.utcnow().isoformat(),
        'eventType': 'lambda-invocation',
        'payload': json.dumps(event),
        'functionName': context.function_name
    })

    # Publish to SNS if alert condition
    if event.get('alert'):
        sns.publish(
            TopicArn=os.environ.get('SNS_TOPIC_ARN', ''),
            Message=f"Alert from Lambda: {json.dumps(event)}",
            Subject="Kiro Lab Alert"
        )

    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
        'body': json.dumps({
            'message': 'Processed successfully',
            'eventId': event_id,
            'timestamp': datetime.utcnow().isoformat()
        })
    }
PYEOF
    filename = "lambda_function.py"
  }
}

data "archive_file" "lambda_s3_processor" {
  type        = "zip"
  output_path = "/tmp/lambda_s3_processor.zip"
  source {
    content  = <<-PYEOF
import json
import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb', region_name=os.environ.get('AWS_REGION', 'ap-south-1'))

def handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        size = record['s3']['object'].get('size', 0)
        event_name = record['eventName']

        logger.info(f"S3 event: {event_name} - s3://{bucket}/{key}")

        # Log to DynamoDB
        table = dynamodb.Table(os.environ.get('EVENTS_TABLE', ''))
        table.put_item(Item={
            'eventId': f"s3-{context.aws_request_id}",
            'timestamp': record['eventTime'],
            'eventType': 's3-event',
            'bucket': bucket,
            'key': key,
            'size': size,
            'eventName': event_name
        })

    return {'statusCode': 200, 'body': 'OK'}
PYEOF
    filename = "lambda_function.py"
  }
}

data "archive_file" "lambda_scheduler" {
  type        = "zip"
  output_path = "/tmp/lambda_scheduler.zip"
  source {
    content  = <<-PYEOF
import json
import boto3
import os
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2', region_name=os.environ.get('AWS_REGION', 'ap-south-1'))
cloudwatch = boto3.client('cloudwatch', region_name=os.environ.get('AWS_REGION', 'ap-south-1'))

def handler(event, context):
    """Scheduled health check - runs every hour via EventBridge"""
    logger.info("Running scheduled health check")

    # Get EC2 instance statuses
    response = ec2.describe_instance_status(IncludeAllInstances=True)
    instances = response.get('InstanceStatuses', [])

    healthy = sum(1 for i in instances if i['InstanceState']['Name'] == 'running')
    total = len(instances)

    # Publish custom metric
    cloudwatch.put_metric_data(
        Namespace='KiroLab/Health',
        MetricData=[{
            'MetricName': 'HealthyInstances',
            'Value': healthy,
            'Unit': 'Count',
            'Dimensions': [{'Name': 'Environment', 'Value': 'lab'}]
        }]
    )

    logger.info(f"Health check complete: {healthy}/{total} instances healthy")
    return {'statusCode': 200, 'healthy': healthy, 'total': total}
PYEOF
    filename = "lambda_function.py"
  }
}

# Lambda: API Processor
resource "aws_lambda_function" "processor" {
  filename         = data.archive_file.lambda_processor.output_path
  function_name    = "${local.name}-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128 # Free tier: 400,000 GB-seconds

  source_code_hash = data.archive_file.lambda_processor.output_base64sha256

  environment {
    variables = {
      EVENTS_TABLE  = aws_dynamodb_table.events.name
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
      AWS_ACCOUNT   = data.aws_caller_identity.current.account_id
    }
  }

  tracing_config { mode = "Active" } # X-Ray tracing (free: 100k traces/mo)

  tags = merge(local.tags, { Name = "${local.name}-processor" })
}

# Lambda: S3 Event Processor
resource "aws_lambda_function" "s3_processor" {
  filename         = data.archive_file.lambda_s3_processor.output_path
  function_name    = "${local.name}-s3-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128

  source_code_hash = data.archive_file.lambda_s3_processor.output_base64sha256

  environment {
    variables = {
      EVENTS_TABLE = aws_dynamodb_table.events.name
    }
  }

  tracing_config { mode = "Active" }
  tags = merge(local.tags, { Name = "${local.name}-s3-processor" })
}

# Lambda: Scheduled Health Check
resource "aws_lambda_function" "scheduler" {
  filename         = data.archive_file.lambda_scheduler.output_path
  function_name    = "${local.name}-scheduler"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 128

  source_code_hash = data.archive_file.lambda_scheduler.output_base64sha256

  environment {
    variables = {
      AWS_ACCOUNT = data.aws_caller_identity.current.account_id
    }
  }

  tracing_config { mode = "Active" }
  tags = merge(local.tags, { Name = "${local.name}-scheduler" })
}

# S3 trigger for Lambda
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.assets.arn
}

# SQS trigger for Lambda
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.processor.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 10
  enabled          = true
}

# API Gateway (Free: 1M calls/mo for 12 months)
resource "aws_api_gateway_rest_api" "lab" {
  name        = "${local.name}-api"
  description = "Kiro Free Tier Lab API"
  tags        = local.tags
}

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.lab.id
  parent_id   = aws_api_gateway_rest_api.lab.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "health_get" {
  rest_api_id   = aws_api_gateway_rest_api.lab.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "health" {
  rest_api_id             = aws_api_gateway_rest_api.lab.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.processor.invoke_arn
}

resource "aws_api_gateway_resource" "process" {
  rest_api_id = aws_api_gateway_rest_api.lab.id
  parent_id   = aws_api_gateway_rest_api.lab.root_resource_id
  path_part   = "process"
}

resource "aws_api_gateway_method" "process_post" {
  rest_api_id   = aws_api_gateway_rest_api.lab.id
  resource_id   = aws_api_gateway_resource.process.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "process" {
  rest_api_id             = aws_api_gateway_rest_api.lab.id
  resource_id             = aws_api_gateway_resource.process.id
  http_method             = aws_api_gateway_method.process_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.processor.invoke_arn
}

resource "aws_api_gateway_deployment" "lab" {
  rest_api_id = aws_api_gateway_rest_api.lab.id
  depends_on  = [aws_api_gateway_integration.health, aws_api_gateway_integration.process]
}

resource "aws_api_gateway_stage" "lab" {
  deployment_id = aws_api_gateway_deployment.lab.id
  rest_api_id   = aws_api_gateway_rest_api.lab.id
  stage_name    = "lab"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format          = jsonencode({ requestId = "$context.requestId", ip = "$context.identity.sourceIp", httpMethod = "$context.httpMethod", path = "$context.path", status = "$context.status", responseLength = "$context.responseLength" })
  }

  tags = local.tags
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lab.execution_arn}/*/*"
}

# EventBridge Rule - Scheduled (Free: always free)
resource "aws_cloudwatch_event_rule" "hourly" {
  name                = "${local.name}-hourly-check"
  description         = "Trigger health check Lambda every hour"
  schedule_expression = "rate(1 hour)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "scheduler" {
  rule      = aws_cloudwatch_event_rule.hourly.name
  target_id = "SchedulerLambda"
  arn       = aws_lambda_function.scheduler.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.hourly.arn
}
