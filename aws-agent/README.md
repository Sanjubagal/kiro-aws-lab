# AWS Agent — Kiro Free Tier Lab

A fully automated AWS environment monitoring and cost analysis system built with three specialized agents, backed by Terraform-provisioned infrastructure on AWS Free Tier.

## Project Structure

```
aws-agent/
├── agents/                    # Agent definitions
│   ├── infra-agent.json       # InfraMonitor — EC2 + CloudWatch health
│   ├── cost-agent.json        # CostAnalyzer — Cost Explorer anomalies
│   └── devops-agent.json      # DevOpsReviewer — Security + ops review
│
├── scripts/                   # Agent runners
│   ├── run_infra_agent.py     # Run InfraMonitor standalone
│   ├── run_cost_agent.py      # Run CostAnalyzer standalone
│   └── daily_report.py        # ★ Run all 3 agents → HTML report
│
├── terraform/                 # Infrastructure as Code (AWS Free Tier)
│   ├── main.tf                # Provider config, random suffix
│   ├── networking.tf          # VPC, subnets, IGW, route tables
│   ├── compute.tf             # EC2 web + app servers (t3.micro)
│   ├── database.tf            # RDS MySQL (db.t3.micro)
│   ├── serverless.tf          # Lambda, API Gateway, EventBridge
│   ├── storage.tf             # S3 buckets (assets, logs, lambda-code)
│   ├── messaging.tf           # SNS topics + SQS queues
│   ├── monitoring.tf          # CloudWatch alarms, dashboard, CloudTrail
│   ├── iam.tf                 # IAM roles and policies
│   ├── security-groups.tf     # Security group rules
│   ├── secrets-config.tf      # Secrets Manager + SSM parameters
│   ├── outputs.tf             # Terraform outputs
│   ├── variables.tf           # Input variables
│   └── README.md              # Terraform-specific docs
│
├── reports/                   # Generated HTML reports (daily)
│   └── aws-report-YYYY-MM-DD.html
│
├── mcp-config.yaml            # MCP server config (CloudWatch, CE, EC2)
├── .gitignore
└── README.md
```

## Agents

### 🖥️ InfraMonitor (`infra-agent.json`)
Checks server health, alarms, and performance metrics.
- EC2 instance state, CPU, network I/O, system/instance status checks
- RDS status, CPU, connections, free storage
- All 6 CloudWatch alarms
- Lambda invocations, errors, throttles, duration
- Log group error scanning (last 24h)

### 💰 CostAnalyzer (`cost-agent.json`)
Analyzes AWS spending trends, detects anomalies, and recommends savings.
- Monthly spend totals and per-service breakdown
- Daily trend with 2σ statistical anomaly detection
- AWS native Cost Anomaly Detection (CE monitors)
- Month-over-month comparison
- Cost saving recommendations (rightsizing, idle resources, lifecycle policies)

### 🔧 DevOpsReviewer (`devops-agent.json`)
Combines infra health and cost data for optimization recommendations.
- Security group audit (open 0.0.0.0/0 rules)
- SQS queue depths (DLQ monitoring)
- DynamoDB table utilization
- Security, reliability, and cost recommendations

## Daily Report

The `daily_report.py` script runs all 3 agents **in parallel** and generates a consolidated dark-themed HTML report.

### Run manually

```bash
# Install dependency
pip3 install boto3

# Run (saves to reports/aws-report-YYYY-MM-DD.html)
python3 scripts/daily_report.py

# Custom output path
python3 scripts/daily_report.py --output /path/to/report.html
```

### Schedule with cron (daily at 07:00)

```bash
# Edit crontab
crontab -e

# Add this line (adjust python3 path as needed)
0 7 * * * /usr/bin/python3 /path/to/aws-agent/scripts/daily_report.py >> /tmp/kiro-daily-report.log 2>&1
```

### Report sections

| Section | Agent | Content |
|---|---|---|
| KPI Summary | All | EC2 health, alarm counts, spend, savings count |
| EC2 Instances | InfraMonitor | State, CPU bar chart, network I/O |
| RDS Database | InfraMonitor | Status, CPU, connections, free storage |
| CloudWatch Alarms | InfraMonitor | All alarms with state and reason |
| Lambda Functions | InfraMonitor | Invocations, errors, throttles, duration |
| Log Errors | InfraMonitor | Last 24h ERROR filter |
| Daily Spend Trend | CostAnalyzer | Line chart with 2σ anomaly threshold |
| Cost by Service | CostAnalyzer | Bar chart + table with % share |
| Month-over-Month | CostAnalyzer | Color-coded delta per service |
| Cost Anomalies | CostAnalyzer | Native CE + statistical anomalies |
| 💡 Cost Savings | CostAnalyzer | Rightsizing, idle resources, lifecycle |
| Security Groups | DevOpsReviewer | Open rules flagged |
| SQS Queues | DevOpsReviewer | Depths, DLQ highlighted |
| DynamoDB Tables | DevOpsReviewer | Items, size, RCU/WCU |
| DevOps Recs | DevOpsReviewer | Security, reliability, cost findings |

## Infrastructure (AWS Free Tier)

Deployed in `ap-south-1`. All resources stay within AWS Free Tier limits.

| Service | Resource | Free Tier |
|---|---|---|
| EC2 | 2× t3.micro | 750 hrs/mo |
| RDS | db.t3.micro MySQL | 750 hrs/mo |
| Lambda | 3 functions | 1M req/mo |
| DynamoDB | 3 tables | 25GB + 25 RCU/WCU |
| S3 | 3 buckets | 5GB |
| CloudWatch | 6 alarms, dashboard | 10 alarms, 5GB logs |
| SNS/SQS | 3 topics / 3 queues | 1M req/mo |
| API Gateway | 1 REST API | 1M calls/mo |

## Prerequisites

```bash
# AWS CLI configured
aws configure

# Terraform
brew install terraform

# Python dependency
pip3 install boto3
```

## Deploy Infrastructure

```bash
cd terraform
terraform init
terraform apply \
  -var="my_ip=$(curl -s ifconfig.me)/32" \
  -var="alert_email=your@email.com"
```

## Destroy (avoid charges)

```bash
cd terraform
terraform destroy -var="my_ip=$(curl -s ifconfig.me)/32"
```

## MCP Configuration

The `mcp-config.yaml` configures three MCP servers (CloudWatch, Cost Explorer, EC2) used by the agents. Set your AWS credentials as environment variables:

```bash
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
```
