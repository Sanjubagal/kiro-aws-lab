#!/bin/bash

# AWS Infrastructure Daily Report Generator
# Generates a comprehensive HTML report with EC2, RDS, and Cost data

# Configuration
REPORT_DIR="${HOME}/aws-reports"
DATE=$(date +"%Y-%m-%d")
TIME=$(date +"%H:%M:%S")
REPORT_FILE="${REPORT_DIR}/infra-report-${DATE}.html"
REGION="ap-south-1"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create reports directory if it doesn't exist
mkdir -p "${REPORT_DIR}"

echo -e "${GREEN}=== AWS Infrastructure Daily Report ===${NC}"
echo "Generating report for ${DATE} ${TIME}..."

# Get EC2 Instance Data
echo -e "${YELLOW}Fetching EC2 instances...${NC}"
EC2_DATA=$(aws ec2 describe-instances \
  --region ${REGION} \
  --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],InstanceId,InstanceType,State.Name,PublicIpAddress,PrivateIpAddress,AvailabilityZone]' \
  --output json 2>/dev/null)

EC2_COUNT=$(echo "${EC2_DATA}" | jq '[.[][]] | length' 2>/dev/null || echo "0")
EC2_RUNNING=$(echo "${EC2_DATA}" | jq '[.[][] | select(.[3] == "running")] | length' 2>/dev/null || echo "0")
EC2_STOPPED=$(echo "${EC2_DATA}" | jq '[.[][] | select(.[3] == "stopped")] | length' 2>/dev/null || echo "0")

# Get RDS Data
echo -e "${YELLOW}Fetching RDS instances...${NC}"
RDS_DATA=$(aws rds describe-db-instances \
  --region ${REGION} \
  --query 'DBInstances[*].[DBInstanceIdentifier,Engine,EngineVersion,DBInstanceClass,AllocatedStorage,DBInstanceStatus,AvailabilityZone,MultiAZ]' \
  --output json 2>/dev/null)

RDS_COUNT=$(echo "${RDS_DATA}" | jq 'length' 2>/dev/null || echo "0")
RDS_AVAILABLE=$(echo "${RDS_DATA}" | jq '[.[] | select(.[4] == "available")] | length' 2>/dev/null || echo "0")

# Get CloudWatch Alarms
echo -e "${YELLOW}Fetching CloudWatch alarms...${NC}"
ALARMS_DATA=$(aws cloudwatch describe-alarms \
  --region ${REGION} \
  --query 'MetricAlarms[*].[AlarmName,StateValue,Namespace,MetricName]' \
  --output json 2>/dev/null)

ALARM_COUNT=$(echo "${ALARMS_DATA}" | jq 'length' 2>/dev/null || echo "0")
ALARM_ALARM=$(echo "${ALARMS_DATA}" | jq '[.[] | select(.[1] == "ALARM")] | length' 2>/dev/null || echo "0")
ALARM_OK=$(echo "${ALARMS_DATA}" | jq '[.[] | select(.[1] == "OK")] | length' 2>/dev/null || echo "0")

# Get Cost Data (Last 30 days)
echo -e "${YELLOW}Fetching cost data...${NC}"
END_DATE=$(date +"%Y-%m-%d")
START_DATE=$(date -v-30d +"%Y-%m-%d" 2>/dev/null || date -d "30 days ago" +"%Y-%m-%d")

COST_DATA=$(aws ce get-cost-and-usage \
  --time-period Start=${START_DATE},End=${END_DATE} \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region ${REGION} \
  --output json 2>/dev/null)

TOTAL_COST=$(echo "${COST_DATA}" | jq '[.ResultsByTime[].Groups[].Metrics.BlendedCost.Amount | tonumber] | add // 0' 2>/dev/null || echo "0")
TOTAL_COST_FORMATTED=$(printf "%.2f" "${TOTAL_COST}")

# Get S3 Buckets
echo -e "${YELLOW}Fetching S3 buckets...${NC}"
S3_DATA=$(aws s3 ls --output json 2>/dev/null || echo "[]")
S3_COUNT=$(aws s3 ls 2>/dev/null | wc -l | tr -d ' ')

# Determine overall health status
if [ "${EC2_RUNNING}" -eq "${EC2_COUNT}" ] && [ "${RDS_AVAILABLE}" -eq "${RDS_COUNT}" ] && [ "${ALARM_ALARM}" -eq 0 ]; then
    HEALTH_STATUS="Healthy"
    HEALTH_COLOR="#28a745"
    HEALTH_ICON="✅"
else
    HEALTH_STATUS="Warning"
    HEALTH_COLOR="#ffc107"
    HEALTH_ICON="⚠️"
fi

# Generate HTML Report
echo -e "${YELLOW}Generating HTML report...${NC}"

cat > "${REPORT_FILE}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AWS Infrastructure Daily Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            padding: 20px;
            color: #fff;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        .header {
            text-align: center;
            padding: 30px 0;
            border-bottom: 1px solid rgba(255,255,255,0.1);
            margin-bottom: 30px;
        }
        .header h1 {
            font-size: 2.5em;
            background: linear-gradient(90deg, #00d4ff, #7b2cbf);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        .header .subtitle {
            color: #888;
            margin-top: 10px;
        }
        .status-banner {
            background: HEALTH_COLOR;
            border-radius: 12px;
            padding: 20px;
            text-align: center;
            margin-bottom: 30px;
            font-size: 1.5em;
            font-weight: bold;
        }
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .metric-card {
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 25px;
            border: 1px solid rgba(255,255,255,0.1);
            transition: transform 0.3s ease;
        }
        .metric-card:hover {
            transform: translateY(-5px);
            border-color: #00d4ff;
        }
        .metric-card .icon {
            font-size: 2.5em;
            margin-bottom: 15px;
        }
        .metric-card .title {
            color: #888;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .metric-card .value {
            font-size: 2.5em;
            font-weight: bold;
            margin: 10px 0;
        }
        .metric-card .detail {
            color: #666;
            font-size: 0.85em;
        }
        .section {
            background: rgba(255,255,255,0.03);
            border-radius: 12px;
            padding: 25px;
            margin-bottom: 25px;
            border: 1px solid rgba(255,255,255,0.1);
        }
        .section h2 {
            color: #00d4ff;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 1px solid rgba(255,255,255,0.1);
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid rgba(255,255,255,0.1);
        }
        th {
            background: rgba(0,212,255,0.1);
            color: #00d4ff;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.8em;
            letter-spacing: 1px;
        }
        tr:hover {
            background: rgba(255,255,255,0.02);
        }
        .status-running {
            color: #28a745;
            font-weight: bold;
        }
        .status-stopped {
            color: #dc3545;
            font-weight: bold;
        }
        .status-available {
            color: #28a745;
            font-weight: bold;
        }
        .status-alarm {
            color: #dc3545;
            font-weight: bold;
        }
        .status-ok {
            color: #28a745;
        }
        .cost-highlight {
            color: #ffc107;
            font-size: 1.2em;
            font-weight: bold;
        }
        .footer {
            text-align: center;
            padding: 30px 0;
            color: #666;
            font-size: 0.9em;
            border-top: 1px solid rgba(255,255,255,0.1);
            margin-top: 30px;
        }
        .recommendations {
            background: rgba(255,193,7,0.1);
            border-left: 4px solid #ffc107;
        }
        .recommendations ul {
            margin-left: 20px;
            margin-top: 15px;
        }
        .recommendations li {
            margin-bottom: 10px;
            color: #ddd;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 AWS Infrastructure Report</h1>
            <div class="subtitle">Generated on DATE_PLACEHOLDER at TIME_PLACEHOLDER | Region: ${REGION}</div>
        </div>
        
        <div class="status-banner" style="background: HEALTH_COLOR_PLACEHOLDER;">
            HEALTH_ICON_PLACEHOLDER Overall Status: HEALTH_STATUS_PLACEHOLDER
        </div>
        
        <div class="metrics-grid">
            <div class="metric-card">
                <div class="icon">🖥️</div>
                <div class="title">EC2 Instances</div>
                <div class="value">EC2_COUNT_PLACEHOLDER</div>
                <div class="detail">Running: EC2_RUNNING_PLACEHOLDER | Stopped: EC2_STOPPED_PLACEHOLDER</div>
            </div>
            <div class="metric-card">
                <div class="icon">🗄️</div>
                <div class="title">RDS Databases</div>
                <div class="value">RDS_COUNT_PLACEHOLDER</div>
                <div class="detail">Available: RDS_AVAILABLE_PLACEHOLDER</div>
            </div>
            <div class="metric-card">
                <div class="icon">🔔</div>
                <div class="title">CloudWatch Alarms</div>
                <div class="value">ALARM_COUNT_PLACEHOLDER</div>
                <div class="detail">OK: ALARM_OK_PLACEHOLDER | In Alarm: ALARM_ALARM_PLACEHOLDER</div>
            </div>
            <div class="metric-card">
                <div class="icon">💰</div>
                <div class="title">Monthly Cost (30d)</div>
                <div class="value cost-highlight">$TOTAL_COST_PLACEHOLDER</div>
                <div class="detail">From START_DATE_PLACEHOLDER to END_DATE_PLACEHOLDER</div>
            </div>
            <div class="metric-card">
                <div class="icon">🪣</div>
                <div class="title">S3 Buckets</div>
                <div class="value">S3_COUNT_PLACEHOLDER</div>
                <div class="detail">Total buckets</div>
            </div>
        </div>
        
        <div class="section">
            <h2>🖥️ EC2 Instances</h2>
            <table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Instance ID</th>
                        <th>Type</th>
                        <th>State</th>
                        <th>Public IP</th>
                        <th>Private IP</th>
                        <th>AZ</th>
                    </tr>
                </thead>
                <tbody>
                    EC2_TABLE_ROWS_PLACEHOLDER
                </tbody>
            </table>
        </div>
        
        <div class="section">
            <h2>🗄️ RDS Databases</h2>
            <table>
                <thead>
                    <tr>
                        <th>Identifier</th>
                        <th>Engine</th>
                        <th>Version</th>
                        <th>Class</th>
                        <th>Storage</th>
                        <th>Status</th>
                        <th>Multi-AZ</th>
                    </tr>
                </thead>
                <tbody>
                    RDS_TABLE_ROWS_PLACEHOLDER
                </tbody>
            </table>
        </div>
        
        <div class="section">
            <h2>🔔 CloudWatch Alarms</h2>
            ALARMS_TABLE_PLACEHOLDER
        </div>
        
        <div class="section">
            <h2>💰 Cost Breakdown (Last 30 Days)</h2>
            COST_TABLE_PLACEHOLDER
        </div>
        
        <div class="section recommendations">
            <h2>💡 Recommendations</h2>
            <ul>
                <li><strong>Security:</strong> Restrict SSH access (port 22) to specific IP ranges instead of 0.0.0.0/0</li>
                <li><strong>Security:</strong> Enable EBS encryption for EC2 volumes</li>
                <li><strong>Security:</strong> Enable storage encryption for RDS</li>
                <li><strong>Reliability:</strong> Add CloudWatch alarms for CPU, memory, and status checks</li>
                <li><strong>Reliability:</strong> Enable Multi-AZ for RDS production databases</li>
                <li><strong>Backup:</strong> Enable automated backups for RDS</li>
                <li><strong>Cost:</strong> Consider Reserved Instances for long-running workloads</li>
                <li><strong>Cost:</strong> Review and terminate unused resources</li>
            </ul>
        </div>
        
        <div class="footer">
            <p>Generated by AWS Infrastructure Report Generator | Report saved to: ${REPORT_FILE}</p>
            <p>Run daily via cron: <code>0 9 * * * ~/kiro-aws-lab/scripts/infra-report.sh</code></p>
        </div>
    </div>
</body>
</html>
HTMLEOF

# Generate EC2 table rows
EC2_TABLE_ROWS=""
if [ "${EC2_COUNT}" -gt 0 ]; then
    for row in $(echo "${EC2_DATA}" | jq -r '.[][] | @base64' 2>/dev/null); do
        row_data=$(echo "${row}" | base64 --decode)
        name=$(echo "${row_data}" | jq -r '.[0] // "N/A"')
        instance_id=$(echo "${row_data}" | jq -r '.[1] // "N/A"')
        instance_type=$(echo "${row_data}" | jq -r '.[2] // "N/A"')
        state=$(echo "${row_data}" | jq -r '.[3] // "N/A"')
        public_ip=$(echo "${row_data}" | jq -r '.[4] // "N/A"')
        private_ip=$(echo "${row_data}" | jq -r '.[5] // "N/A"')
        az=$(echo "${row_data}" | jq -r '.[6] // "N/A"')
        
        state_class="status-${state}"
        EC2_TABLE_ROWS="${EC2_TABLE_ROWS}<tr><td>${name}</td><td>${instance_id}</td><td>${instance_type}</td><td class=\"${state_class}\">${state}</td><td>${public_ip}</td><td>${private_ip}</td><td>${az}</td></tr>"
    done
else
    EC2_TABLE_ROWS="<tr><td colspan='7' style='text-align:center;color:#888;'>No EC2 instances found</td></tr>"
fi

# Generate RDS table rows
RDS_TABLE_ROWS=""
if [ "${RDS_COUNT}" -gt 0 ]; then
    for row in $(echo "${RDS_DATA}" | jq -r '.[] | @base64' 2>/dev/null); do
        row_data=$(echo "${row}" | base64 --decode)
        identifier=$(echo "${row_data}" | jq -r '.[0] // "N/A"')
        engine=$(echo "${row_data}" | jq -r '.[1] // "N/A"')
        version=$(echo "${row_data}" | jq -r '.[2] // "N/A"')
        class=$(echo "${row_data}" | jq -r '.[3] // "N/A"')
        storage=$(echo "${row_data}" | jq -r '.[4] // "N/A"')
        status=$(echo "${row_data}" | jq -r '.[5] // "N/A"')
        multiaz=$(echo "${row_data}" | jq -r '.[7] // false')
        
        status_class="status-${status}"
        multiaz_display=$([ "${multiaz}" = "true" ] && echo "Yes" || echo "No")
        RDS_TABLE_ROWS="${RDS_TABLE_ROWS}<tr><td>${identifier}</td><td>${engine}</td><td>${version}</td><td>${class}</td><td>${storage}GB</td><td class=\"${status_class}\">${status}</td><td>${multiaz_display}</td></tr>"
    done
else
    RDS_TABLE_ROWS="<tr><td colspan='7' style='text-align:center;color:#888;'>No RDS instances found</td></tr>"
fi

# Generate Alarms table
ALARMS_TABLE=""
if [ "${ALARM_COUNT}" -gt 0 ]; then
    ALARMS_TABLE="<table><thead><tr><th>Alarm Name</th><th>State</th><th>Namespace</th><th>Metric</th></tr></thead><tbody>"
    for row in $(echo "${ALARMS_DATA}" | jq -r '.[] | @base64' 2>/dev/null); do
        row_data=$(echo "${row}" | base64 --decode)
        alarm_name=$(echo "${row_data}" | jq -r '.[0] // "N/A"')
        state=$(echo "${row_data}" | jq -r '.[1] // "N/A"')
        namespace=$(echo "${row_data}" | jq -r '.[2] // "N/A"')
        metric=$(echo "${row_data}" | jq -r '.[3] // "N/A"')
        
        state_class="status-${state,,}"
        ALARMS_TABLE="${ALARMS_TABLE}<tr><td>${alarm_name}</td><td class=\"${state_class}\">${state}</td><td>${namespace}</td><td>${metric}</td></tr>"
    done
    ALARMS_TABLE="${ALARMS_TABLE}</tbody></table>"
else
    ALARMS_TABLE="<p style='color:#888;'>No CloudWatch alarms configured. Consider adding alarms for critical metrics.</p>"
fi

# Generate Cost table
COST_TABLE=""
if [ "${TOTAL_COST}" != "0" ] && [ -n "${COST_DATA}" ]; then
    COST_TABLE="<table><thead><tr><th>Service</th><th>Cost (USD)</th></tr></thead><tbody>"
    for row in $(echo "${COST_DATA}" | jq -r '.ResultsByTime[].Groups[] | @base64' 2>/dev/null | head -10); do
        row_data=$(echo "${row}" | base64 --decode)
        service=$(echo "${row_data}" | jq -r '.Keys[0] // "N/A"')
        cost=$(echo "${row_data}" | jq -r '.Metrics.BlendedCost.Amount // "0"')
        cost_formatted=$(printf "%.2f" "${cost}")
        COST_TABLE="${COST_TABLE}<tr><td>${service}</td><td>\$${cost_formatted}</td></tr>"
    done
    COST_TABLE="${COST_TABLE}<tr style='font-weight:bold;border-top:2px solid rgba(255,255,255,0.2);'><td>Total</td><td>\$${TOTAL_COST_FORMATTED}</td></tr></tbody></table>"
else
    COST_TABLE="<p style='color:#888;'>Unable to retrieve cost data. Ensure Cost Explorer is enabled and you have permissions.</p>"
fi

# Replace placeholders in HTML
sed -i.bak \
    -e "s|DATE_PLACEHOLDER|${DATE}|g" \
    -e "s|TIME_PLACEHOLDER|${TIME}|g" \
    -e "s|HEALTH_COLOR_PLACEHOLDER|${HEALTH_COLOR}|g" \
    -e "s|HEALTH_ICON_PLACEHOLDER|${HEALTH_ICON}|g" \
    -e "s|HEALTH_STATUS_PLACEHOLDER|${HEALTH_STATUS}|g" \
    -e "s|EC2_COUNT_PLACEHOLDER|${EC2_COUNT}|g" \
    -e "s|EC2_RUNNING_PLACEHOLDER|${EC2_RUNNING}|g" \
    -e "s|EC2_STOPPED_PLACEHOLDER|${EC2_STOPPED}|g" \
    -e "s|RDS_COUNT_PLACEHOLDER|${RDS_COUNT}|g" \
    -e "s|RDS_AVAILABLE_PLACEHOLDER|${RDS_AVAILABLE}|g" \
    -e "s|ALARM_COUNT_PLACEHOLDER|${ALARM_COUNT}|g" \
    -e "s|ALARM_OK_PLACEHOLDER|${ALARM_OK}|g" \
    -e "s|ALARM_ALARM_PLACEHOLDER|${ALARM_ALARM}|g" \
    -e "s|TOTAL_COST_PLACEHOLDER|${TOTAL_COST_FORMATTED}|g" \
    -e "s|START_DATE_PLACEHOLDER|${START_DATE}|g" \
    -e "s|END_DATE_PLACEHOLDER|${END_DATE}|g" \
    -e "s|S3_COUNT_PLACEHOLDER|${S3_COUNT}|g" \
    -e "s|EC2_TABLE_ROWS_PLACEHOLDER|${EC2_TABLE_ROWS}|g" \
    -e "s|RDS_TABLE_ROWS_PLACEHOLDER|${RDS_TABLE_ROWS}|g" \
    -e "s|ALARMS_TABLE_PLACEHOLDER|${ALARMS_TABLE}|g" \
    -e "s|COST_TABLE_PLACEHOLDER|${COST_TABLE}|g" \
    "${REPORT_FILE}"

rm -f "${REPORT_FILE}.bak"

echo ""
echo -e "${GREEN}✅ Report generated successfully!${NC}"
echo -e "📄 Report saved to: ${REPORT_FILE}"
echo ""
echo "To view the report:"
echo "  open ${REPORT_FILE}"
echo ""
echo "To run daily at 9 AM, add to crontab:"
echo "  crontab -e"
echo "  0 9 * * * ${PWD}/infra-report.sh"
