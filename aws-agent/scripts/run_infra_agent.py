#!/usr/bin/env python3
"""
InfraMonitor Agent Runner
Role: AWS Infrastructure Health Assistant
Tools: CloudWatch + EC2
Instructions: Check server health, alarms, and performance metrics. Provide concise status reports.
"""

import boto3
import json
from datetime import datetime, timezone, timedelta

REGION = "ap-south-1"

# Resource IDs from Terraform state
RESOURCES = {
    "ec2_web":   "i-0c13a2652dfb32401",
    "ec2_app":   "i-0e470a958427b3621",
    "alarms": [
        "freetier-lab-1c95748f-web-cpu-high",
        "freetier-lab-1c95748f-web-status-check",
        "freetier-lab-1c95748f-rds-cpu-high",
        "freetier-lab-1c95748f-rds-storage-low",
        "freetier-lab-1c95748f-lambda-errors",
        "freetier-lab-1c95748f-dlq-messages",
    ],
    "lambda_functions": [
        "freetier-lab-1c95748f-processor",
        "freetier-lab-1c95748f-s3-processor",
        "freetier-lab-1c95748f-scheduler",
    ],
}

ec2_client      = boto3.client("ec2",         region_name=REGION)
cw_client       = boto3.client("cloudwatch",  region_name=REGION)
logs_client     = boto3.client("logs",        region_name=REGION)

SEPARATOR = "=" * 60
now        = datetime.now(timezone.utc)
period_start = now - timedelta(hours=1)


# ── helpers ──────────────────────────────────────────────────────────────────

def get_latest_metric(namespace, metric_name, dimensions, stat="Average", period=300):
    resp = cw_client.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=dimensions,
        StartTime=period_start,
        EndTime=now,
        Period=period,
        Statistics=[stat],
    )
    points = sorted(resp["Datapoints"], key=lambda x: x["Timestamp"])
    if points:
        return round(points[-1][stat], 2), points[-1]["Timestamp"].strftime("%H:%M UTC")
    return None, "no data"


def status_icon(state):
    return {"OK": "✅", "ALARM": "🔴", "INSUFFICIENT_DATA": "⚠️"}.get(state, "❓")


def health_icon(state):
    return "✅" if state == "running" else "🔴"


# ── 1. EC2 Instance Health ────────────────────────────────────────────────────

def check_ec2():
    print(f"\n{SEPARATOR}")
    print("  EC2 INSTANCE HEALTH")
    print(SEPARATOR)

    instance_ids = [RESOURCES["ec2_web"], RESOURCES["ec2_app"]]
    resp = ec2_client.describe_instances(InstanceIds=instance_ids)
    status_resp = ec2_client.describe_instance_status(
        InstanceIds=instance_ids, IncludeAllInstances=True
    )

    status_map = {s["InstanceId"]: s for s in status_resp["InstanceStatuses"]}

    for reservation in resp["Reservations"]:
        for inst in reservation["Instances"]:
            iid   = inst["InstanceId"]
            itype = inst["InstanceType"]
            state = inst["State"]["Name"]
            az    = inst["Placement"]["AvailabilityZone"]
            name  = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), iid)
            role  = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Role"), "")
            pub_ip = inst.get("PublicIpAddress", "N/A")

            s = status_map.get(iid, {})
            sys_check  = s.get("SystemStatus",   {}).get("Status", "N/A")
            inst_check = s.get("InstanceStatus", {}).get("Status", "N/A")

            # CPU metric
            cpu, cpu_ts = get_latest_metric(
                "AWS/EC2", "CPUUtilization",
                [{"Name": "InstanceId", "Value": iid}]
            )

            print(f"\n  {health_icon(state)} {name}  [{role}]")
            print(f"     ID        : {iid}")
            print(f"     Type      : {itype}  |  AZ: {az}")
            print(f"     State     : {state}")
            print(f"     Public IP : {pub_ip}")
            print(f"     Sys check : {sys_check}  |  Inst check: {inst_check}")
            cpu_str = f"{cpu}%" if cpu is not None else "no data"
            print(f"     CPU (1h)  : {cpu_str}  @ {cpu_ts}")


# ── 2. CloudWatch Alarms ──────────────────────────────────────────────────────

def check_alarms():
    print(f"\n{SEPARATOR}")
    print("  CLOUDWATCH ALARMS")
    print(SEPARATOR)

    resp = cw_client.describe_alarms(AlarmNames=RESOURCES["alarms"])
    alarms = resp.get("MetricAlarms", [])

    counts = {"OK": 0, "ALARM": 0, "INSUFFICIENT_DATA": 0}
    for alarm in alarms:
        state = alarm["StateValue"]
        counts[state] = counts.get(state, 0) + 1
        icon  = status_icon(state)
        updated = alarm["StateUpdatedTimestamp"].strftime("%Y-%m-%d %H:%M UTC")
        print(f"\n  {icon} {alarm['AlarmName']}")
        print(f"     State   : {state}  (updated {updated})")
        print(f"     Metric  : {alarm['Namespace']} / {alarm['MetricName']}")
        print(f"     Reason  : {alarm['StateReason'][:120]}")

    print(f"\n  Summary → ✅ OK: {counts['OK']}  🔴 ALARM: {counts['ALARM']}  ⚠️  Insufficient: {counts['INSUFFICIENT_DATA']}")


# ── 3. Lambda Performance ─────────────────────────────────────────────────────

def check_lambda():
    print(f"\n{SEPARATOR}")
    print("  LAMBDA FUNCTION METRICS  (last 1 hour)")
    print(SEPARATOR)

    for fn in RESOURCES["lambda_functions"]:
        dims = [{"Name": "FunctionName", "Value": fn}]

        invocations, _ = get_latest_metric("AWS/Lambda", "Invocations", dims, stat="Sum")
        errors, _      = get_latest_metric("AWS/Lambda", "Errors",      dims, stat="Sum")
        duration, _    = get_latest_metric("AWS/Lambda", "Duration",    dims, stat="Average")
        throttles, _   = get_latest_metric("AWS/Lambda", "Throttles",   dims, stat="Sum")

        inv_str  = str(invocations)  if invocations  is not None else "0"
        err_str  = str(errors)       if errors        is not None else "0"
        dur_str  = f"{duration} ms"  if duration      is not None else "no data"
        thr_str  = str(throttles)    if throttles     is not None else "0"

        err_icon = "🔴" if (errors or 0) > 0 else "✅"
        print(f"\n  {err_icon} {fn}")
        print(f"     Invocations : {inv_str}  |  Errors: {err_str}  |  Throttles: {thr_str}")
        print(f"     Avg Duration: {dur_str}")


# ── 4. Recent CloudWatch Log Errors ──────────────────────────────────────────

def check_log_errors():
    print(f"\n{SEPARATOR}")
    print("  RECENT LOG ERRORS  (last 1 hour)")
    print(SEPARATOR)

    log_groups = ["/kiro-lab/app", "/kiro-lab/web"]
    start_ms = int(period_start.timestamp() * 1000)
    end_ms   = int(now.timestamp() * 1000)

    for lg in log_groups:
        try:
            resp = logs_client.filter_log_events(
                logGroupName=lg,
                startTime=start_ms,
                endTime=end_ms,
                filterPattern="ERROR",
                limit=5,
            )
            events = resp.get("events", [])
            if events:
                print(f"\n  🔴 {lg}  ({len(events)} error(s) found)")
                for e in events:
                    ts = datetime.fromtimestamp(e["timestamp"] / 1000, tz=timezone.utc).strftime("%H:%M:%S UTC")
                    print(f"     [{ts}] {e['message'][:120].strip()}")
            else:
                print(f"\n  ✅ {lg}  — no errors in last hour")
        except logs_client.exceptions.ResourceNotFoundException:
            print(f"\n  ⚠️  {lg}  — log group not found (agent may not have started yet)")
        except Exception as e:
            print(f"\n  ⚠️  {lg}  — {e}")


# ── 5. Summary ────────────────────────────────────────────────────────────────

def print_summary(start_time):
    elapsed = round((datetime.now(timezone.utc) - start_time).total_seconds(), 1)
    print(f"\n{SEPARATOR}")
    print(f"  InfraMonitor run complete  ({elapsed}s)  —  {now.strftime('%Y-%m-%d %H:%M UTC')}")
    print(SEPARATOR)


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    run_start = datetime.now(timezone.utc)
    print(f"\n{'#' * 60}")
    print(f"  🤖 InfraMonitor Agent  —  AWS Infrastructure Health Report")
    print(f"  Region: {REGION}  |  {now.strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"{'#' * 60}")

    check_ec2()
    check_alarms()
    check_lambda()
    check_log_errors()
    print_summary(run_start)
