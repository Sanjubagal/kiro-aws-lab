# AWS Free Tier Complex Lab

A comprehensive AWS lab environment using **only free tier resources** for full agent testing.

## Architecture

```
                          ┌─────────────────────────────────────────────────────┐
                          │                    VPC (10.0.0.0/16)                │
                          │                                                     │
  Internet ──── IGW ────► │  Public Subnets (a/b/c)    Private Subnets (a/b)   │
                          │  ┌──────────┐ ┌──────────┐  ┌──────────────────┐   │
                          │  │ Web EC2  │ │ App EC2  │  │   RDS MySQL      │   │
                          │  │t2.micro  │ │t2.micro  │  │   db.t2.micro    │   │
                          │  └────┬─────┘ └────┬─────┘  └──────────────────┘   │
                          │       │             │                               │
                          └───────┼─────────────┼───────────────────────────────┘
                                  │             │
              ┌───────────────────┼─────────────┼──────────────────────┐
              │                   ▼             ▼                      │
              │  ┌──────────┐  ┌──────────────────────┐               │
              │  │API GW    │  │     Lambda Functions  │               │
              │  │REST API  │  │  processor / s3 / cron│               │
              │  └──────────┘  └──────────┬────────────┘               │
              │                           │                            │
              │  ┌──────────┐  ┌──────────▼────────────┐               │
              │  │  SNS     │  │       DynamoDB         │               │
              │  │3 Topics  │  │  users/events/config   │               │
              │  └──────────┘  └───────────────────────┘               │
              │                                                        │
              │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
              │  │   SQS    │  │    S3    │  │CloudWatch│             │
              │  │3 Queues  │  │3 Buckets │  │6 Alarms  │             │
              │  └──────────┘  └──────────┘  └──────────┘             │
              └────────────────────────────────────────────────────────┘
```

## Free Tier Resources Used

| Service | Resource | Free Tier Limit |
|---------|----------|-----------------|
| **EC2** | 2x t2.micro | 750 hrs/mo (12 months) |
| **RDS** | 1x db.t2.micro MySQL | 750 hrs/mo (12 months) |
| **RDS Storage** | 20GB gp2 | 20GB (12 months) |
| **EBS** | 2x 8GB gp2 | 30GB total (12 months) |
| **S3** | 3 buckets | 5GB storage (12 months) |
| **Lambda** | 3 functions | 1M requests/mo (always free) |
| **DynamoDB** | 3 tables | 25GB + 25 RCU/WCU (always free) |
| **SNS** | 3 topics | 1M publishes/mo (always free) |
| **SQS** | 3 queues | 1M requests/mo (always free) |
| **API Gateway** | 1 REST API | 1M calls/mo (12 months) |
| **CloudWatch** | 6 alarms, logs, dashboard | 10 alarms, 5GB logs (always free) |
| **CloudTrail** | 1 trail | Management events (always free) |
| **IAM** | Roles, policies | Always free |
| **VPC** | VPC, subnets, IGW, SGs | Always free |
| **VPC Endpoints** | S3 + DynamoDB | Always free |
| **SSM Parameter Store** | 7 parameters | Standard params (always free) |
| **Secrets Manager** | 1 secret | 30-day free trial |
| **EventBridge** | 1 rule | Always free |
| **X-Ray** | Tracing on Lambda | 100k traces/mo (always free) |
| **Elastic IP** | 1 EIP (attached) | Free when attached |

## Prerequisites

```bash
# Install Terraform
brew install terraform

# Configure AWS CLI
aws configure

# Create SSH key if not exists
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
```

## Deploy

```bash
cd kiro-aws-lab/free-tier-lab

# Initialize
terraform init

# Preview
terraform plan -var="my_ip=$(curl -s ifconfig.me)/32" -var="alert_email=your@email.com"

# Deploy
terraform apply -var="my_ip=$(curl -s ifconfig.me)/32" -var="alert_email=your@email.com"
```

## Test the Lab

```bash
# Get outputs
terraform output

# Test API Gateway
API_URL=$(terraform output -raw api_gateway_url)
curl $API_URL/health
curl -X POST $API_URL/process -d '{"test": "hello"}'

# Test Lambda directly
aws lambda invoke --function-name $(terraform output -raw lambda_processor_arn | cut -d: -f7) \
  --payload '{"message": "test"}' /tmp/response.json
cat /tmp/response.json

# Check DynamoDB
aws dynamodb scan --table-name $(terraform output -raw dynamodb_events_table)

# Send SNS message
aws sns publish --topic-arn $(terraform output -raw sns_alerts_arn) \
  --message "Test alert from lab" --subject "Lab Test"

# Send SQS message
aws sqs send-message --queue-url $(terraform output -raw sqs_processor_url) \
  --message-body '{"action": "test", "data": "hello"}'
```

## Destroy (to avoid any charges)

```bash
terraform destroy -var="my_ip=$(curl -s ifconfig.me)/32"
```

## Agent Testing Scenarios

This lab supports testing all 3 Kiro agents:

### infra-monitor
- Check EC2 health (web + app servers)
- Monitor RDS status and connections
- Review CloudWatch alarms (6 configured)
- Check VPC flow logs

### cost-analyzer
- Analyze spend across EC2, RDS, Lambda, S3, DynamoDB
- Identify optimization opportunities
- Review DynamoDB capacity utilization
- Check Lambda invocation costs

### devops-reviewer
- Full infrastructure health + cost review
- Security group analysis
- IAM role review
- CloudTrail audit log review
- Multi-service optimization recommendations
