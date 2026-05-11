#!/usr/bin/env python3
"""
Daily AWS Environment Report
Runs all 3 agents (InfraMonitor, CostAnalyzer, DevOpsReviewer) and
produces a consolidated HTML report with cost-saving recommendations.

Usage:
    python3 daily_report.py
    python3 daily_report.py --output /path/to/report.html

Schedule (cron example — runs every day at 07:00):
    0 7 * * * /usr/bin/python3 /path/to/daily_report.py >> /var/log/kiro-report.log 2>&1
"""

import boto3
import json
import os
import sys
import argparse
from datetime import datetime, timezone, timedelta
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Config ────────────────────────────────────────────────────────────────────
REGION     = "ap-south-1"
CE_REGION  = "us-east-1"   # Cost Explorer is always us-east-1
ACCOUNT_ID = "814466573226"
LAB_PREFIX = "freetier-lab-1c95748f"

RESOURCES = {
    "ec2_web": "i-0c13a2652dfb32401",
    "ec2_app": "i-0e470a958427b3621",
    "alarms": [
        f"{LAB_PREFIX}-web-cpu-high",
        f"{LAB_PREFIX}-web-status-check",
        f"{LAB_PREFIX}-rds-cpu-high",
        f"{LAB_PREFIX}-rds-storage-low",
        f"{LAB_PREFIX}-lambda-errors",
        f"{LAB_PREFIX}-dlq-messages",
    ],
    "lambda_functions": [
        f"{LAB_PREFIX}-processor",
        f"{LAB_PREFIX}-s3-processor",
        f"{LAB_PREFIX}-scheduler",
    ],
    "rds_instance": f"{LAB_PREFIX}-mysql",
    "sqs_dlq":      f"{LAB_PREFIX}-processor-dlq",
    "dynamodb_tables": [
        f"{LAB_PREFIX}-users",
        f"{LAB_PREFIX}-events",
        f"{LAB_PREFIX}-config",
    ],
}

now           = datetime.now(timezone.utc)
today_str     = now.strftime("%Y-%m-%d")
report_ts     = now.strftime("%Y-%m-%d %H:%M UTC")
period_start  = now - timedelta(hours=24)

# Cost Explorer date windows
this_month_start = now.replace(day=1).strftime("%Y-%m-%d")
last_month_end   = now.replace(day=1).strftime("%Y-%m-%d")
last_month_dt    = (now.replace(day=1) - timedelta(days=1)).replace(day=1)
last_month_start = last_month_dt.strftime("%Y-%m-%d")
prev_month_start = (last_month_dt.replace(day=1) - timedelta(days=1)).replace(day=1).strftime("%Y-%m-%d")

# ── AWS clients ───────────────────────────────────────────────────────────────
ec2  = boto3.client("ec2",         region_name=REGION)
cw   = boto3.client("cloudwatch",  region_name=REGION)
logs = boto3.client("logs",        region_name=REGION)
ce   = boto3.client("ce",          region_name=CE_REGION)
rds  = boto3.client("rds",         region_name=REGION)
lmb  = boto3.client("lambda",      region_name=REGION)
sqs  = boto3.client("sqs",         region_name=REGION)
ddb  = boto3.client("dynamodb",    region_name=REGION)

# ── Helpers ───────────────────────────────────────────────────────────────────
def fmt_usd(val):
    v = float(val)
    return f"${v:.4f}" if v < 1 else f"${v:.2f}"

def get_metric(namespace, metric_name, dimensions, stat="Average", period=3600, hours=24):
    start = now - timedelta(hours=hours)
    resp = cw.get_metric_statistics(
        Namespace=namespace, MetricName=metric_name,
        Dimensions=dimensions, StartTime=start, EndTime=now,
        Period=period, Statistics=[stat],
    )
    points = sorted(resp["Datapoints"], key=lambda x: x["Timestamp"])
    if points:
        return round(points[-1][stat], 2), points[-1]["Timestamp"].strftime("%H:%M UTC")
    return None, "no data"


# ══════════════════════════════════════════════════════════════════════════════
# AGENT 1 — InfraMonitor
# ══════════════════════════════════════════════════════════════════════════════
def run_infra_agent():
    print("  [InfraMonitor] collecting data...")
    data = {"ec2": [], "alarms": [], "lambda": [], "log_errors": [], "rds": {}}

    # EC2
    try:
        resp   = ec2.describe_instances(InstanceIds=[RESOURCES["ec2_web"], RESOURCES["ec2_app"]])
        st_resp = ec2.describe_instance_status(
            InstanceIds=[RESOURCES["ec2_web"], RESOURCES["ec2_app"]], IncludeAllInstances=True
        )
        status_map = {s["InstanceId"]: s for s in st_resp["InstanceStatuses"]}
        for res in resp["Reservations"]:
            for inst in res["Instances"]:
                iid   = inst["InstanceId"]
                state = inst["State"]["Name"]
                name  = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), iid)
                role  = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Role"), "")
                s     = status_map.get(iid, {})
                cpu, cpu_ts = get_metric("AWS/EC2", "CPUUtilization",
                                         [{"Name": "InstanceId", "Value": iid}])
                net_in, _  = get_metric("AWS/EC2", "NetworkIn",
                                        [{"Name": "InstanceId", "Value": iid}], stat="Sum")
                net_out, _ = get_metric("AWS/EC2", "NetworkOut",
                                        [{"Name": "InstanceId", "Value": iid}], stat="Sum")
                data["ec2"].append({
                    "id": iid, "name": name, "role": role,
                    "type": inst["InstanceType"], "state": state,
                    "az": inst["Placement"]["AvailabilityZone"],
                    "public_ip": inst.get("PublicIpAddress", "N/A"),
                    "sys_check":  s.get("SystemStatus",   {}).get("Status", "N/A"),
                    "inst_check": s.get("InstanceStatus", {}).get("Status", "N/A"),
                    "cpu": cpu, "cpu_ts": cpu_ts,
                    "net_in":  round(net_in  / 1024, 1) if net_in  else 0,
                    "net_out": round(net_out / 1024, 1) if net_out else 0,
                })
    except Exception as e:
        data["ec2_error"] = str(e)

    # CloudWatch Alarms
    try:
        resp = cw.describe_alarms(AlarmNames=RESOURCES["alarms"])
        for alarm in resp.get("MetricAlarms", []):
            data["alarms"].append({
                "name":    alarm["AlarmName"],
                "state":   alarm["StateValue"],
                "metric":  f"{alarm['Namespace']} / {alarm['MetricName']}",
                "reason":  alarm["StateReason"][:150],
                "updated": alarm["StateUpdatedTimestamp"].strftime("%Y-%m-%d %H:%M UTC"),
            })
    except Exception as e:
        data["alarms_error"] = str(e)

    # Lambda
    try:
        for fn in RESOURCES["lambda_functions"]:
            dims = [{"Name": "FunctionName", "Value": fn}]
            inv, _  = get_metric("AWS/Lambda", "Invocations", dims, stat="Sum")
            err, _  = get_metric("AWS/Lambda", "Errors",      dims, stat="Sum")
            dur, _  = get_metric("AWS/Lambda", "Duration",    dims, stat="Average")
            thr, _  = get_metric("AWS/Lambda", "Throttles",   dims, stat="Sum")
            data["lambda"].append({
                "name": fn,
                "invocations": inv or 0, "errors": err or 0,
                "duration": dur, "throttles": thr or 0,
            })
    except Exception as e:
        data["lambda_error"] = str(e)

    # Log errors (last 24h)
    try:
        start_ms = int(period_start.timestamp() * 1000)
        end_ms   = int(now.timestamp() * 1000)
        for lg in ["/kiro-lab/app", "/kiro-lab/web"]:
            try:
                resp = logs.filter_log_events(
                    logGroupName=lg, startTime=start_ms, endTime=end_ms,
                    filterPattern="ERROR", limit=10,
                )
                events = resp.get("events", [])
                data["log_errors"].append({
                    "group": lg, "count": len(events),
                    "samples": [e["message"][:120].strip() for e in events[:3]],
                })
            except logs.exceptions.ResourceNotFoundException:
                data["log_errors"].append({"group": lg, "count": 0, "samples": [], "missing": True})
    except Exception as e:
        data["log_error"] = str(e)

    # RDS
    try:
        resp = rds.describe_db_instances(DBInstanceIdentifier=RESOURCES["rds_instance"])
        db = resp["DBInstances"][0]
        cpu_rds, _ = get_metric("AWS/RDS", "CPUUtilization",
                                [{"Name": "DBInstanceIdentifier", "Value": RESOURCES["rds_instance"]}])
        conn, _    = get_metric("AWS/RDS", "DatabaseConnections",
                                [{"Name": "DBInstanceIdentifier", "Value": RESOURCES["rds_instance"]}])
        storage, _ = get_metric("AWS/RDS", "FreeStorageSpace",
                                [{"Name": "DBInstanceIdentifier", "Value": RESOURCES["rds_instance"]}])
        data["rds"] = {
            "id":      db["DBInstanceIdentifier"],
            "status":  db["DBInstanceStatus"],
            "class":   db["DBInstanceClass"],
            "engine":  f"{db['Engine']} {db['EngineVersion']}",
            "storage": db["AllocatedStorage"],
            "cpu":     cpu_rds,
            "connections": conn,
            "free_storage_gb": round(float(storage) / 1e9, 2) if storage else None,
        }
    except Exception as e:
        data["rds_error"] = str(e)

    print("  [InfraMonitor] done.")
    return data


# ══════════════════════════════════════════════════════════════════════════════
# AGENT 2 — CostAnalyzer
# ══════════════════════════════════════════════════════════════════════════════
def run_cost_agent():
    print("  [CostAnalyzer] collecting data...")
    data = {
        "last_month_total": 0, "this_month_total": 0,
        "by_service_last": [], "by_service_this": [],
        "daily_trend": [], "anomalies_stat": [],
        "ce_anomalies": [], "mom_comparison": [],
        "savings": [],
    }

    # Last month total + by service
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": last_month_start, "End": last_month_end},
            Granularity="MONTHLY", Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
        groups = resp["ResultsByTime"][0]["Groups"]
        services = sorted(
            [(g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])) for g in groups],
            key=lambda x: x[1], reverse=True,
        )
        data["by_service_last"] = [(s, c) for s, c in services if c > 0]
        data["last_month_total"] = sum(c for _, c in services)
    except Exception as e:
        data["cost_error"] = str(e)

    # This month so far
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": this_month_start, "End": today_str},
            Granularity="MONTHLY", Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
        groups = resp["ResultsByTime"][0]["Groups"]
        services = sorted(
            [(g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])) for g in groups],
            key=lambda x: x[1], reverse=True,
        )
        data["by_service_this"] = [(s, c) for s, c in services if c > 0]
        data["this_month_total"] = sum(c for _, c in services)
    except Exception as e:
        data["cost_this_error"] = str(e)

    # Daily trend last month
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": last_month_start, "End": last_month_end},
            Granularity="DAILY", Metrics=["UnblendedCost"],
        )
        daily = [(r["TimePeriod"]["Start"], float(r["Total"]["UnblendedCost"]["Amount"]))
                 for r in resp["ResultsByTime"]]
        data["daily_trend"] = daily
        costs = [c for _, c in daily]
        if costs:
            avg = sum(costs) / len(costs)
            std = (sum((c - avg) ** 2 for c in costs) / len(costs)) ** 0.5
            threshold = avg + 2 * std
            data["daily_avg"]       = avg
            data["daily_threshold"] = threshold
            data["anomalies_stat"]  = [(d, c) for d, c in daily if c > threshold and threshold > 0]
    except Exception as e:
        data["daily_error"] = str(e)

    # Native CE anomaly detection
    try:
        monitors = ce.get_anomaly_monitors().get("AnomalyMonitors", [])
        for monitor in monitors:
            anomalies = ce.get_anomalies(
                MonitorArn=monitor["MonitorArn"],
                DateInterval={"StartDate": last_month_start, "EndDate": last_month_end},
            ).get("Anomalies", [])
            for a in anomalies:
                rc = a.get("RootCauses", [{}])[0]
                data["ce_anomalies"].append({
                    "start":  a["AnomalyStartDate"],
                    "end":    a.get("AnomalyEndDate", "ongoing"),
                    "service": rc.get("Service", "Unknown"),
                    "region":  rc.get("Region", "Unknown"),
                    "impact":  float(a.get("Impact", {}).get("TotalImpact", 0)),
                    "score":   a.get("AnomalyScore", {}).get("MaxScore", 0),
                })
    except Exception as e:
        data["ce_anomaly_error"] = str(e)

    # Month-over-month
    try:
        resp_prev = ce.get_cost_and_usage(
            TimePeriod={"Start": prev_month_start, "End": last_month_start},
            Granularity="MONTHLY", Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
        prev_map = {g["Keys"][0]: float(g["Metrics"]["UnblendedCost"]["Amount"])
                    for g in resp_prev["ResultsByTime"][0]["Groups"]}
        curr_map = dict(data["by_service_last"])
        for svc in sorted(set(list(prev_map) + list(curr_map))):
            prev = prev_map.get(svc, 0)
            curr = curr_map.get(svc, 0)
            if prev == 0 and curr == 0:
                continue
            pct = ((curr - prev) / prev * 100) if prev > 0 else None
            data["mom_comparison"].append({"service": svc, "prev": prev, "curr": curr, "pct": pct})
    except Exception as e:
        data["mom_error"] = str(e)

    # ── Cost savings analysis ──────────────────────────────────────────────
    savings = []

    # 1. Low CPU EC2 instances → rightsizing
    try:
        for iid, name in [(RESOURCES["ec2_web"], "web-server"), (RESOURCES["ec2_app"], "app-server")]:
            cpu, _ = get_metric("AWS/EC2", "CPUUtilization",
                                [{"Name": "InstanceId", "Value": iid}], hours=24*7)
            if cpu is not None and cpu < 5:
                savings.append({
                    "category": "EC2 Rightsizing",
                    "severity": "medium",
                    "resource": name,
                    "finding":  f"Average CPU {cpu}% over 7 days — instance is over-provisioned",
                    "action":   "Consider switching to t3.nano or t4g.nano (~50% cheaper). "
                                "Or use a Savings Plan / Reserved Instance for predictable workloads.",
                    "est_saving": "~$3–5/mo per instance",
                })
    except Exception:
        pass

    # 2. Idle Lambda functions
    try:
        for fn in RESOURCES["lambda_functions"]:
            dims = [{"Name": "FunctionName", "Value": fn}]
            inv, _ = get_metric("AWS/Lambda", "Invocations", dims, stat="Sum", hours=24*7)
            if (inv or 0) == 0:
                savings.append({
                    "category": "Lambda Idle",
                    "severity": "low",
                    "resource": fn,
                    "finding":  "Zero invocations in the last 7 days",
                    "action":   "Review if this function is still needed. "
                                "Lambda itself is free-tier but attached resources (logs, X-Ray) accrue cost.",
                    "est_saving": "Minimal — but reduces clutter and log storage costs",
                })
    except Exception:
        pass

    # 3. RDS — check if it could be Aurora Serverless or paused
    try:
        conn, _ = get_metric("AWS/RDS", "DatabaseConnections",
                             [{"Name": "DBInstanceIdentifier", "Value": RESOURCES["rds_instance"]}],
                             hours=24*7)
        if (conn or 0) < 2:
            savings.append({
                "category": "RDS Optimization",
                "severity": "high",
                "resource": RESOURCES["rds_instance"],
                "finding":  f"Average DB connections: {conn or 0} over 7 days — RDS is mostly idle",
                "action":   "For dev/lab workloads consider: (1) Stop the RDS instance when not in use "
                            "(saves ~$0.017/hr), (2) Migrate to Aurora Serverless v2 which scales to 0, "
                            "(3) Use DynamoDB instead for simple key-value access patterns.",
                "est_saving": "~$12–15/mo if stopped nights/weekends",
            })
    except Exception:
        pass

    # 4. S3 lifecycle policies
    savings.append({
        "category": "S3 Lifecycle",
        "severity": "low",
        "resource": f"{LAB_PREFIX}-logs",
        "finding":  "Log bucket has no lifecycle policy — logs accumulate indefinitely",
        "action":   "Add S3 lifecycle rule: transition to S3-IA after 30 days, "
                    "Glacier after 90 days, delete after 365 days.",
        "est_saving": "Prevents unbounded storage growth; saves ~60–70% on log storage long-term",
    })

    # 5. CloudWatch log retention
    savings.append({
        "category": "CloudWatch Logs",
        "severity": "low",
        "resource": "All log groups",
        "finding":  "Log groups set to 7-day retention — good, but verify no groups are set to 'Never expire'",
        "action":   "Run: aws logs describe-log-groups --query "
                    "'logGroups[?retentionInDays==`null`].logGroupName' to find unbounded groups.",
        "est_saving": "Avoids $0.03/GB/mo for logs beyond free tier (5GB)",
    })

    # 6. Elastic IP
    savings.append({
        "category": "Elastic IP",
        "severity": "info",
        "resource": f"{LAB_PREFIX}-web-eip",
        "finding":  "EIP is attached and free. If the EC2 instance is stopped, the EIP will incur charges.",
        "action":   "Always stop EC2 and release EIP together, or use a script to release on stop.",
        "est_saving": "$0.005/hr (~$3.60/mo) if accidentally left unattached",
    })

    data["savings"] = savings
    print("  [CostAnalyzer] done.")
    return data


# ══════════════════════════════════════════════════════════════════════════════
# AGENT 3 — DevOpsReviewer
# ══════════════════════════════════════════════════════════════════════════════
def run_devops_agent():
    print("  [DevOpsReviewer] collecting data...")
    data = {"security_groups": [], "sqs": [], "dynamodb": [], "recommendations": []}

    # Security group audit
    try:
        resp = ec2.describe_security_groups(
            Filters=[{"Name": "tag:Project", "Values": ["kiro-free-tier-lab"]}]
        )
        for sg in resp["SecurityGroups"]:
            risky_rules = []
            for rule in sg.get("IpPermissions", []):
                for cidr in rule.get("IpRanges", []):
                    if cidr.get("CidrIp") == "0.0.0.0/0":
                        port = rule.get("FromPort", "all")
                        proto = rule.get("IpProtocol", "all")
                        risky_rules.append(f"0.0.0.0/0 → {proto}:{port}")
            data["security_groups"].append({
                "id":   sg["GroupId"],
                "name": sg["GroupName"],
                "risky_rules": risky_rules,
            })
    except Exception as e:
        data["sg_error"] = str(e)

    # SQS queue depths
    try:
        for qname in [f"{LAB_PREFIX}-processor", f"{LAB_PREFIX}-processor-dlq", f"{LAB_PREFIX}-s3-events"]:
            try:
                url_resp = sqs.get_queue_url(QueueName=qname)
                attrs = sqs.get_queue_attributes(
                    QueueUrl=url_resp["QueueUrl"],
                    AttributeNames=["ApproximateNumberOfMessages",
                                    "ApproximateNumberOfMessagesNotVisible",
                                    "NumberOfMessagesSent"],
                )["Attributes"]
                data["sqs"].append({
                    "name":    qname,
                    "visible": int(attrs.get("ApproximateNumberOfMessages", 0)),
                    "in_flight": int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)),
                })
            except Exception as eq:
                data["sqs"].append({"name": qname, "error": str(eq)})
    except Exception as e:
        data["sqs_error"] = str(e)

    # DynamoDB table sizes
    try:
        for tname in RESOURCES["dynamodb_tables"]:
            try:
                desc = ddb.describe_table(TableName=tname)["Table"]
                data["dynamodb"].append({
                    "name":   tname,
                    "status": desc["TableStatus"],
                    "items":  desc.get("ItemCount", 0),
                    "size_kb": round(desc.get("TableSizeBytes", 0) / 1024, 1),
                    "rcu": desc["ProvisionedThroughput"]["ReadCapacityUnits"],
                    "wcu": desc["ProvisionedThroughput"]["WriteCapacityUnits"],
                })
            except Exception as et:
                data["dynamodb"].append({"name": tname, "error": str(et)})
    except Exception as e:
        data["ddb_error"] = str(e)

    # DevOps recommendations
    recs = []

    # Check for open SSH
    for sg in data.get("security_groups", []):
        for rule in sg.get("risky_rules", []):
            if ":22" in rule or "all" in rule.lower():
                recs.append({
                    "type": "security",
                    "severity": "high",
                    "title": f"Open inbound rule in {sg['name']}",
                    "detail": f"Rule '{rule}' allows unrestricted access. "
                              "Restrict SSH (port 22) to your specific IP CIDR.",
                })

    # DLQ messages
    for q in data.get("sqs", []):
        if "dlq" in q.get("name", "") and q.get("visible", 0) > 0:
            recs.append({
                "type": "reliability",
                "severity": "high",
                "title": f"Messages in DLQ: {q['name']}",
                "detail": f"{q['visible']} unprocessed messages. "
                          "Investigate Lambda processor errors and replay or purge.",
            })

    # DynamoDB over-provisioned
    for t in data.get("dynamodb", []):
        if t.get("rcu", 0) > 5 and t.get("items", 0) < 100:
            recs.append({
                "type": "cost",
                "severity": "medium",
                "title": f"DynamoDB over-provisioned: {t['name']}",
                "detail": f"Table has {t['items']} items but {t['rcu']} RCU / {t['wcu']} WCU provisioned. "
                          "Switch to PAY_PER_REQUEST billing mode for low-traffic tables.",
            })

    recs.append({
        "type": "reliability",
        "severity": "info",
        "title": "Enable RDS automated backups verification",
        "detail": "Confirm RDS automated backups are enabled and retention is set to ≥7 days "
                  "for point-in-time recovery.",
    })

    recs.append({
        "type": "security",
        "severity": "info",
        "title": "Rotate IAM credentials",
        "detail": "Ensure the terraform IAM user access keys are rotated every 90 days. "
                  "Consider switching to IAM roles with short-lived credentials.",
    })

    data["recommendations"] = recs
    print("  [DevOpsReviewer] done.")
    return data


# ══════════════════════════════════════════════════════════════════════════════
# HTML REPORT GENERATOR
# ══════════════════════════════════════════════════════════════════════════════
def severity_badge(sev):
    colors = {"high": "#e53e3e", "medium": "#dd6b20", "low": "#d69e2e", "info": "#3182ce"}
    return f'<span class="badge" style="background:{colors.get(sev,"#718096")}">{sev.upper()}</span>'

def state_badge(state):
    if state in ("running", "ok", "available", "ACTIVE"):
        return f'<span class="badge ok">{state}</span>'
    elif state in ("ALARM", "stopped", "error"):
        return f'<span class="badge alarm">{state}</span>'
    else:
        return f'<span class="badge warn">{state}</span>'

def pct_bar(value, max_val=100, warn=70, crit=90):
    if value is None:
        return '<span class="na">N/A</span>'
    pct = min(float(value), max_val)
    color = "#e53e3e" if pct >= crit else "#dd6b20" if pct >= warn else "#48bb78"
    return (f'<div class="bar-wrap"><div class="bar" style="width:{pct}%;background:{color}"></div>'
            f'<span class="bar-label">{value}%</span></div>')

def generate_html(infra, cost, devops, elapsed):
    # ── summary counts ──
    ec2_ok    = sum(1 for i in infra.get("ec2", []) if i["state"] == "running")
    ec2_total = len(infra.get("ec2", []))
    alarm_ok  = sum(1 for a in infra.get("alarms", []) if a["state"] == "OK")
    alarm_bad = sum(1 for a in infra.get("alarms", []) if a["state"] == "ALARM")
    alarm_ins = sum(1 for a in infra.get("alarms", []) if a["state"] == "INSUFFICIENT_DATA")
    lambda_err = sum(1 for l in infra.get("lambda", []) if (l.get("errors") or 0) > 0)
    log_errs  = sum(lg.get("count", 0) for lg in infra.get("log_errors", []))
    savings_count = len(cost.get("savings", []))
    recs_high = sum(1 for r in devops.get("recommendations", []) if r["severity"] == "high")
    rds_status = infra.get("rds", {}).get("status", "unknown")

    overall = "HEALTHY"
    overall_color = "#48bb78"
    if alarm_bad > 0 or recs_high > 0 or lambda_err > 0:
        overall = "NEEDS ATTENTION"
        overall_color = "#e53e3e"
    elif alarm_ins > 0 or log_errs > 0:
        overall = "WARNING"
        overall_color = "#dd6b20"

    # ── daily trend chart data ──
    trend_labels = json.dumps([d for d, _ in cost.get("daily_trend", [])])
    trend_values = json.dumps([round(c, 6) for _, c in cost.get("daily_trend", [])])
    threshold_val = cost.get("daily_threshold", 0)

    # ── service cost chart ──
    svc_labels = json.dumps([s[:30] for s, _ in cost.get("by_service_last", [])[:8]])
    svc_values = json.dumps([round(c, 6) for _, c in cost.get("by_service_last", [])[:8]])

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AWS Daily Report — {today_str}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {{
    --bg: #0f1117; --card: #1a1d27; --border: #2d3148;
    --text: #e2e8f0; --muted: #718096; --accent: #667eea;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
          background: var(--bg); color: var(--text); padding: 24px; font-size: 14px; }}
  h1 {{ font-size: 22px; font-weight: 700; }}
  h2 {{ font-size: 16px; font-weight: 600; margin-bottom: 14px; color: #a0aec0; text-transform: uppercase; letter-spacing: .05em; }}
  h3 {{ font-size: 14px; font-weight: 600; margin-bottom: 8px; }}
  .header {{ display:flex; justify-content:space-between; align-items:center;
             border-bottom: 1px solid var(--border); padding-bottom: 16px; margin-bottom: 24px; }}
  .header-meta {{ font-size:12px; color:var(--muted); text-align:right; }}
  .overall {{ display:inline-block; padding:6px 16px; border-radius:20px; font-weight:700;
              font-size:13px; color:#fff; background:{overall_color}; margin-top:6px; }}
  .grid {{ display:grid; gap:16px; }}
  .grid-2 {{ grid-template-columns: repeat(2, 1fr); }}
  .grid-3 {{ grid-template-columns: repeat(3, 1fr); }}
  .grid-4 {{ grid-template-columns: repeat(4, 1fr); }}
  .card {{ background:var(--card); border:1px solid var(--border); border-radius:10px; padding:20px; }}
  .stat-card {{ text-align:center; }}
  .stat-num {{ font-size:32px; font-weight:800; line-height:1; margin:8px 0 4px; }}
  .stat-label {{ font-size:12px; color:var(--muted); }}
  .badge {{ display:inline-block; padding:2px 8px; border-radius:4px; font-size:11px;
            font-weight:600; color:#fff; }}
  .badge.ok {{ background:#276749; }}
  .badge.alarm {{ background:#9b2c2c; }}
  .badge.warn {{ background:#7b341e; }}
  table {{ width:100%; border-collapse:collapse; font-size:13px; }}
  th {{ text-align:left; padding:8px 10px; color:var(--muted); font-weight:500;
        border-bottom:1px solid var(--border); font-size:11px; text-transform:uppercase; }}
  td {{ padding:8px 10px; border-bottom:1px solid #1e2235; vertical-align:middle; }}
  tr:last-child td {{ border-bottom:none; }}
  tr:hover td {{ background:#1e2235; }}
  .bar-wrap {{ display:flex; align-items:center; gap:8px; }}
  .bar {{ height:8px; border-radius:4px; min-width:2px; transition:width .3s; }}
  .bar-label {{ font-size:12px; color:var(--muted); white-space:nowrap; }}
  .na {{ color:var(--muted); font-style:italic; }}
  .section {{ margin-bottom:24px; }}
  .saving-card {{ border-left:3px solid; padding:12px 16px; margin-bottom:10px;
                  background:#161925; border-radius:0 8px 8px 0; }}
  .saving-card.high   {{ border-color:#e53e3e; }}
  .saving-card.medium {{ border-color:#dd6b20; }}
  .saving-card.low    {{ border-color:#d69e2e; }}
  .saving-card.info   {{ border-color:#3182ce; }}
  .saving-title {{ font-weight:600; margin-bottom:4px; }}
  .saving-detail {{ color:#a0aec0; font-size:13px; line-height:1.5; }}
  .saving-est {{ margin-top:6px; font-size:12px; color:#68d391; font-weight:500; }}
  .rec-card {{ border-left:3px solid; padding:12px 16px; margin-bottom:10px;
               background:#161925; border-radius:0 8px 8px 0; }}
  .rec-card.high   {{ border-color:#e53e3e; }}
  .rec-card.medium {{ border-color:#dd6b20; }}
  .rec-card.info   {{ border-color:#3182ce; }}
  .chart-wrap {{ position:relative; height:220px; }}
  .tag {{ display:inline-block; padding:1px 6px; border-radius:3px; font-size:11px;
          background:#2d3748; color:#a0aec0; margin-right:4px; }}
  .footer {{ margin-top:32px; padding-top:16px; border-top:1px solid var(--border);
             font-size:12px; color:var(--muted); display:flex; justify-content:space-between; }}
  @media(max-width:900px) {{ .grid-4,.grid-3,.grid-2 {{ grid-template-columns:1fr; }} }}
</style>
</head>
<body>

<div class="header">
  <div>
    <h1>🤖 AWS Daily Environment Report</h1>
    <div style="color:var(--muted);margin-top:4px">Account: {ACCOUNT_ID} &nbsp;|&nbsp; Region: {REGION} &nbsp;|&nbsp; Lab: {LAB_PREFIX}</div>
    <div class="overall">{overall}</div>
  </div>
  <div class="header-meta">
    Generated: {report_ts}<br>
    Agents: InfraMonitor · CostAnalyzer · DevOpsReviewer<br>
    Run time: {elapsed:.1f}s
  </div>
</div>

<!-- ── Summary KPIs ── -->
<div class="section">
  <div class="grid grid-4">
    <div class="card stat-card">
      <div class="stat-label">EC2 Instances</div>
      <div class="stat-num" style="color:{'#48bb78' if ec2_ok==ec2_total else '#e53e3e'}">{ec2_ok}/{ec2_total}</div>
      <div class="stat-label">running</div>
    </div>
    <div class="card stat-card">
      <div class="stat-label">CW Alarms</div>
      <div class="stat-num" style="color:{'#48bb78' if alarm_bad==0 else '#e53e3e'}">{alarm_ok} OK</div>
      <div class="stat-label">{alarm_bad} alarm · {alarm_ins} insufficient</div>
    </div>
    <div class="card stat-card">
      <div class="stat-label">Last Month Spend</div>
      <div class="stat-num" style="color:#667eea">{fmt_usd(cost.get('last_month_total',0))}</div>
      <div class="stat-label">This month: {fmt_usd(cost.get('this_month_total',0))}</div>
    </div>
    <div class="card stat-card">
      <div class="stat-label">Cost Savings Found</div>
      <div class="stat-num" style="color:#68d391">{savings_count}</div>
      <div class="stat-label">recommendations</div>
    </div>
  </div>
</div>
"""
    return html


def generate_html_body(infra, cost, devops, elapsed):
    """Generate the main body sections of the HTML report."""

    # ── EC2 rows ──
    ec2_rows = ""
    for i in infra.get("ec2", []):
        cpu_bar = pct_bar(i.get("cpu"), warn=70, crit=90)
        ec2_rows += f"""
        <tr>
          <td><strong>{i['name']}</strong><br><span class="tag">{i['id']}</span></td>
          <td>{state_badge(i['state'])}</td>
          <td>{i['type']}</td>
          <td>{i['az']}</td>
          <td>{i.get('public_ip','N/A')}</td>
          <td>{state_badge(i.get('sys_check','N/A'))}</td>
          <td>{cpu_bar}</td>
          <td>{i.get('net_in',0)} KB / {i.get('net_out',0)} KB</td>
        </tr>"""

    # ── RDS ──
    rds = infra.get("rds", {})
    rds_html = ""
    if rds:
        rds_html = f"""
        <tr>
          <td><strong>{rds.get('id','N/A')}</strong></td>
          <td>{state_badge(rds.get('status','unknown'))}</td>
          <td>{rds.get('class','N/A')}</td>
          <td>{rds.get('engine','N/A')}</td>
          <td>{rds.get('storage','N/A')} GB allocated</td>
          <td>{pct_bar(rds.get('cpu'), warn=70, crit=90)}</td>
          <td>{rds.get('connections') or 'N/A'}</td>
          <td>{rds.get('free_storage_gb','N/A')} GB free</td>
        </tr>"""
    elif "rds_error" in infra:
        rds_html = f'<tr><td colspan="8" style="color:#e53e3e">Error: {infra["rds_error"]}</td></tr>'

    # ── Alarm rows ──
    alarm_rows = ""
    for a in infra.get("alarms", []):
        icon = {"OK": "✅", "ALARM": "🔴", "INSUFFICIENT_DATA": "⚠️"}.get(a["state"], "❓")
        alarm_rows += f"""
        <tr>
          <td>{icon} {a['name']}</td>
          <td>{state_badge(a['state'])}</td>
          <td><span class="tag">{a['metric']}</span></td>
          <td style="color:var(--muted);font-size:12px">{a['reason'][:100]}</td>
          <td style="color:var(--muted);font-size:12px">{a['updated']}</td>
        </tr>"""

    # ── Lambda rows ──
    lambda_rows = ""
    for l in infra.get("lambda", []):
        err_color = "#e53e3e" if (l.get("errors") or 0) > 0 else "#48bb78"
        dur_str = f"{l['duration']} ms" if l.get("duration") else "N/A"
        lambda_rows += f"""
        <tr>
          <td>{l['name']}</td>
          <td>{l.get('invocations',0)}</td>
          <td style="color:{err_color};font-weight:600">{l.get('errors',0)}</td>
          <td>{l.get('throttles',0)}</td>
          <td>{dur_str}</td>
        </tr>"""

    # ── Log error rows ──
    log_rows = ""
    for lg in infra.get("log_errors", []):
        if lg.get("missing"):
            log_rows += f'<tr><td>{lg["group"]}</td><td colspan="2"><span class="na">log group not found yet</span></td></tr>'
        elif lg["count"] == 0:
            log_rows += f'<tr><td>{lg["group"]}</td><td>✅ 0</td><td><span class="na">—</span></td></tr>'
        else:
            samples = "<br>".join(f'<code style="font-size:11px">{s}</code>' for s in lg["samples"])
            log_rows += f'<tr><td>{lg["group"]}</td><td style="color:#e53e3e">🔴 {lg["count"]}</td><td>{samples}</td></tr>'

    # ── SQS rows ──
    sqs_rows = ""
    for q in devops.get("sqs", []):
        if "error" in q:
            sqs_rows += f'<tr><td>{q["name"]}</td><td colspan="2" style="color:#e53e3e">{q["error"]}</td></tr>'
        else:
            dlq_flag = " 🔴" if "dlq" in q["name"] and q["visible"] > 0 else ""
            sqs_rows += f'<tr><td>{q["name"]}</td><td>{q["visible"]}{dlq_flag}</td><td>{q["in_flight"]}</td></tr>'

    # ── DynamoDB rows ──
    ddb_rows = ""
    for t in devops.get("dynamodb", []):
        if "error" in t:
            ddb_rows += f'<tr><td>{t["name"]}</td><td colspan="4" style="color:#e53e3e">{t["error"]}</td></tr>'
        else:
            ddb_rows += f"""<tr>
              <td>{t['name']}</td>
              <td>{state_badge(t['status'])}</td>
              <td>{t.get('items',0)}</td>
              <td>{t.get('size_kb',0)} KB</td>
              <td>{t.get('rcu',0)} RCU / {t.get('wcu',0)} WCU</td>
            </tr>"""

    # ── Security group rows ──
    sg_rows = ""
    for sg in devops.get("security_groups", []):
        risky = ", ".join(sg["risky_rules"]) if sg["risky_rules"] else "—"
        risk_color = "#e53e3e" if sg["risky_rules"] else "#48bb78"
        sg_rows += f"""<tr>
          <td>{sg['name']}</td>
          <td><span class="tag">{sg['id']}</span></td>
          <td style="color:{risk_color};font-size:12px">{risky}</td>
        </tr>"""

    # ── Cost service rows ──
    svc_rows_last = ""
    total_last = cost.get("last_month_total", 0)
    for svc, c in cost.get("by_service_last", []):
        pct = (c / total_last * 100) if total_last > 0 else 0
        bar = f'<div class="bar-wrap"><div class="bar" style="width:{min(pct*2,100):.0f}%;background:#667eea"></div><span class="bar-label">{pct:.1f}%</span></div>'
        svc_rows_last += f"<tr><td>{svc}</td><td>{fmt_usd(c)}</td><td>{bar}</td></tr>"
    if not svc_rows_last:
        svc_rows_last = '<tr><td colspan="3" class="na">No spend data — lab may be new</td></tr>'

    # ── MoM rows ──
    mom_rows = ""
    for m in cost.get("mom_comparison", []):
        pct = m.get("pct")
        if pct is None:
            delta_str, delta_color = "new", "#667eea"
        elif pct > 20:
            delta_str, delta_color = f"+{pct:.1f}%", "#e53e3e"
        elif pct < -20:
            delta_str, delta_color = f"{pct:.1f}%", "#48bb78"
        else:
            delta_str, delta_color = f"{pct:+.1f}%", "#a0aec0"
        mom_rows += f"""<tr>
          <td>{m['service']}</td>
          <td>{fmt_usd(m['prev'])}</td>
          <td>{fmt_usd(m['curr'])}</td>
          <td style="color:{delta_color};font-weight:600">{delta_str}</td>
        </tr>"""
    if not mom_rows:
        mom_rows = '<tr><td colspan="4" class="na">No comparison data available</td></tr>'

    # ── Anomaly rows ──
    anomaly_rows = ""
    for a in cost.get("ce_anomalies", []):
        anomaly_rows += f"""<tr>
          <td>🔴 {a['start']} → {a['end']}</td>
          <td>{a['service']}</td>
          <td>{a['region']}</td>
          <td style="color:#e53e3e">{fmt_usd(a['impact'])}</td>
          <td>{a['score']:.2f}</td>
        </tr>"""
    stat_anomalies = cost.get("anomalies_stat", [])
    for d, c in stat_anomalies:
        anomaly_rows += f"""<tr>
          <td>⚠️ {d} (statistical)</td>
          <td colspan="2">Exceeded 2σ threshold</td>
          <td style="color:#dd6b20">{fmt_usd(c)}</td>
          <td>—</td>
        </tr>"""
    if not anomaly_rows:
        anomaly_rows = '<tr><td colspan="5">✅ No anomalies detected</td></tr>'

    # ── Savings cards ──
    savings_html = ""
    for s in cost.get("savings", []):
        est = f'<div class="saving-est">💰 Estimated saving: {s["est_saving"]}</div>' if s.get("est_saving") else ""
        savings_html += f"""
        <div class="saving-card {s['severity']}">
          <div class="saving-title">{severity_badge(s['severity'])} &nbsp;{s['category']} — {s['resource']}</div>
          <div class="saving-detail"><strong>Finding:</strong> {s['finding']}</div>
          <div class="saving-detail"><strong>Action:</strong> {s['action']}</div>
          {est}
        </div>"""

    # ── DevOps recommendation cards ──
    recs_html = ""
    for r in devops.get("recommendations", []):
        type_tag = f'<span class="tag">{r["type"]}</span>'
        recs_html += f"""
        <div class="rec-card {r['severity']}">
          <div class="saving-title">{severity_badge(r['severity'])} {type_tag} &nbsp;{r['title']}</div>
          <div class="saving-detail">{r['detail']}</div>
        </div>"""

    return f"""
<!-- ── AGENT 1: InfraMonitor ── -->
<div class="section">
  <div class="card">
    <h2>🖥️ Agent 1 — InfraMonitor: Infrastructure Health</h2>

    <h3 style="margin-bottom:10px">EC2 Instances</h3>
    <table>
      <thead><tr><th>Name</th><th>State</th><th>Type</th><th>AZ</th><th>Public IP</th><th>Sys Check</th><th>CPU (24h)</th><th>Network In/Out</th></tr></thead>
      <tbody>{ec2_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">RDS Database</h3>
    <table>
      <thead><tr><th>Identifier</th><th>Status</th><th>Class</th><th>Engine</th><th>Storage</th><th>CPU</th><th>Connections</th><th>Free Storage</th></tr></thead>
      <tbody>{rds_html}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">CloudWatch Alarms</h3>
    <table>
      <thead><tr><th>Alarm</th><th>State</th><th>Metric</th><th>Reason</th><th>Last Updated</th></tr></thead>
      <tbody>{alarm_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">Lambda Functions (last 24h)</h3>
    <table>
      <thead><tr><th>Function</th><th>Invocations</th><th>Errors</th><th>Throttles</th><th>Avg Duration</th></tr></thead>
      <tbody>{lambda_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">Log Errors (last 24h)</h3>
    <table>
      <thead><tr><th>Log Group</th><th>Error Count</th><th>Sample Messages</th></tr></thead>
      <tbody>{log_rows}</tbody>
    </table>
  </div>
</div>

<!-- ── AGENT 2: CostAnalyzer ── -->
<div class="section">
  <div class="card">
    <h2>💰 Agent 2 — CostAnalyzer: Cost Analysis &amp; Anomalies</h2>

    <div class="grid grid-2" style="margin-bottom:20px">
      <div>
        <h3 style="margin-bottom:10px">Daily Spend Trend (Last Month)</h3>
        <div class="chart-wrap"><canvas id="trendChart"></canvas></div>
      </div>
      <div>
        <h3 style="margin-bottom:10px">Cost by Service (Last Month)</h3>
        <div class="chart-wrap"><canvas id="svcChart"></canvas></div>
      </div>
    </div>

    <h3 style="margin-bottom:10px">Cost by Service — Last Month</h3>
    <table>
      <thead><tr><th>Service</th><th>Cost</th><th>Share</th></tr></thead>
      <tbody>{svc_rows_last}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">Month-over-Month Comparison</h3>
    <table>
      <thead><tr><th>Service</th><th>Prev Month</th><th>Last Month</th><th>Change</th></tr></thead>
      <tbody>{mom_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">Cost Anomalies</h3>
    <table>
      <thead><tr><th>Period</th><th>Service</th><th>Region</th><th>Impact</th><th>Score</th></tr></thead>
      <tbody>{anomaly_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">💡 Cost Saving Recommendations</h3>
    {savings_html}
  </div>
</div>

<!-- ── AGENT 3: DevOpsReviewer ── -->
<div class="section">
  <div class="card">
    <h2>🔧 Agent 3 — DevOpsReviewer: Operations &amp; Security</h2>

    <h3 style="margin-bottom:10px">Security Groups</h3>
    <table>
      <thead><tr><th>Name</th><th>ID</th><th>Open Rules (0.0.0.0/0)</th></tr></thead>
      <tbody>{sg_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">SQS Queue Depths</h3>
    <table>
      <thead><tr><th>Queue</th><th>Visible Messages</th><th>In-Flight</th></tr></thead>
      <tbody>{sqs_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">DynamoDB Tables</h3>
    <table>
      <thead><tr><th>Table</th><th>Status</th><th>Items</th><th>Size</th><th>Capacity</th></tr></thead>
      <tbody>{ddb_rows}</tbody>
    </table>

    <h3 style="margin:20px 0 10px">🔍 DevOps Recommendations</h3>
    {recs_html}
  </div>
</div>
"""


def generate_full_html(infra, cost, devops, elapsed):
    """Combine header + body + charts + footer into final HTML."""
    header_html = generate_html(infra, cost, devops, elapsed)
    body_html   = generate_html_body(infra, cost, devops, elapsed)

    trend_labels = json.dumps([d for d, _ in cost.get("daily_trend", [])])
    trend_values = json.dumps([round(c, 6) for _, c in cost.get("daily_trend", [])])
    threshold_val = round(cost.get("daily_threshold", 0), 6)
    svc_labels   = json.dumps([s[:28] for s, _ in cost.get("by_service_last", [])[:8]])
    svc_values   = json.dumps([round(c, 6) for _, c in cost.get("by_service_last", [])[:8]])

    charts = f"""
<script>
(function() {{
  const darkGrid = {{ color: 'rgba(255,255,255,0.06)' }};
  const tickColor = '#718096';

  // Daily trend chart
  const tCtx = document.getElementById('trendChart');
  if (tCtx) {{
    new Chart(tCtx, {{
      type: 'line',
      data: {{
        labels: {trend_labels},
        datasets: [
          {{
            label: 'Daily Spend ($)',
            data: {trend_values},
            borderColor: '#667eea',
            backgroundColor: 'rgba(102,126,234,0.15)',
            fill: true, tension: 0.3, pointRadius: 3,
          }},
          {{
            label: '2σ Threshold',
            data: Array({trend_labels}.length).fill({threshold_val}),
            borderColor: '#e53e3e', borderDash: [5,5],
            pointRadius: 0, fill: false,
          }}
        ]
      }},
      options: {{
        responsive: true, maintainAspectRatio: false,
        plugins: {{ legend: {{ labels: {{ color: tickColor }} }} }},
        scales: {{
          x: {{ ticks: {{ color: tickColor, maxTicksLimit: 10 }}, grid: darkGrid }},
          y: {{ ticks: {{ color: tickColor }}, grid: darkGrid }}
        }}
      }}
    }});
  }}

  // Service cost chart
  const sCtx = document.getElementById('svcChart');
  if (sCtx) {{
    new Chart(sCtx, {{
      type: 'bar',
      data: {{
        labels: {svc_labels},
        datasets: [{{
          label: 'Cost ($)',
          data: {svc_values},
          backgroundColor: ['#667eea','#764ba2','#f093fb','#4facfe','#43e97b',
                            '#fa709a','#fee140','#30cfd0'],
        }}]
      }},
      options: {{
        responsive: true, maintainAspectRatio: false, indexAxis: 'y',
        plugins: {{ legend: {{ display: false }} }},
        scales: {{
          x: {{ ticks: {{ color: tickColor }}, grid: darkGrid }},
          y: {{ ticks: {{ color: tickColor }}, grid: darkGrid }}
        }}
      }}
    }});
  }}
}})();
</script>

<div class="footer">
  <span>🤖 Kiro AWS Daily Report &nbsp;|&nbsp; {LAB_PREFIX} &nbsp;|&nbsp; {REGION}</span>
  <span>Generated {report_ts} &nbsp;|&nbsp; Run time: {elapsed:.1f}s</span>
</div>
</body>
</html>"""

    return header_html + body_html + charts


# ══════════════════════════════════════════════════════════════════════════════
# MAIN — run all 3 agents in parallel, generate report
# ══════════════════════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description="Kiro AWS Daily Report")
    parser.add_argument("--output", default="", help="Output HTML file path (default: auto-named in ../reports/)")
    args = parser.parse_args()

    run_start = datetime.now(timezone.utc)
    print(f"\n{'='*60}")
    print(f"  🤖 Kiro AWS Daily Report — {report_ts}")
    print(f"  Running all 3 agents in parallel...")
    print(f"{'='*60}\n")

    # Run all 3 agents concurrently
    results = {}
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {
            pool.submit(run_infra_agent):  "infra",
            pool.submit(run_cost_agent):   "cost",
            pool.submit(run_devops_agent): "devops",
        }
        for future in as_completed(futures):
            key = futures[future]
            try:
                results[key] = future.result()
            except Exception as e:
                print(f"  ⚠️  Agent '{key}' failed: {e}")
                results[key] = {"error": str(e)}

    elapsed = (datetime.now(timezone.utc) - run_start).total_seconds()
    print(f"\n  All agents complete in {elapsed:.1f}s — generating HTML report...")

    infra  = results.get("infra",  {})
    cost   = results.get("cost",   {})
    devops = results.get("devops", {})

    html = generate_full_html(infra, cost, devops, elapsed)

    # Determine output path
    if args.output:
        out_path = args.output
    else:
        reports_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reports")
        os.makedirs(reports_dir, exist_ok=True)
        out_path = os.path.join(reports_dir, f"aws-report-{today_str}.html")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"  ✅ Report saved → {os.path.abspath(out_path)}")
    print(f"\n{'='*60}\n")
    return out_path


if __name__ == "__main__":
    main()

