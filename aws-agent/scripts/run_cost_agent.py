#!/usr/bin/env python3
"""
CostAnalyzer Agent Runner
Role: AWS Cost Analysis Assistant
Tools: Cost Explorer
Instructions: Analyze AWS spending trends, detect anomalies, and explain cost changes.
Period: Last calendar month (April 2026)
"""

import boto3
import json
from datetime import datetime, timezone
from collections import defaultdict

REGION        = "us-east-1"   # Cost Explorer is a global service, endpoint is us-east-1
ACCOUNT_ID    = "814466573226"
LAST_MONTH_START = "2026-04-01"
LAST_MONTH_END   = "2026-05-01"   # exclusive end date for CE API
THIS_MONTH_START = "2026-05-01"
TODAY            = "2026-05-11"

ce = boto3.client("ce", region_name=REGION)

SEPARATOR = "=" * 62
now_str   = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


# ── helpers ───────────────────────────────────────────────────────────────────

def fmt_usd(val):
    return f"${float(val):.4f}" if float(val) < 1 else f"${float(val):.2f}"


def delta_icon(pct):
    if pct is None:
        return "➡️ "
    if pct > 50:
        return "🔴"
    if pct > 20:
        return "🟠"
    if pct < -20:
        return "🟢"
    return "➡️ "


# ── 1. Total cost last month ──────────────────────────────────────────────────

def total_cost_last_month():
    print(f"\n{SEPARATOR}")
    print("  TOTAL COST — April 2026")
    print(SEPARATOR)

    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": LAST_MONTH_START, "End": LAST_MONTH_END},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
    )
    total = float(resp["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"])
    unit  = resp["ResultsByTime"][0]["Total"]["UnblendedCost"]["Unit"]
    print(f"\n  Total spend  : ${total:.4f} {unit}")
    return total


# ── 2. Cost by service ────────────────────────────────────────────────────────

def cost_by_service():
    print(f"\n{SEPARATOR}")
    print("  COST BY SERVICE — April 2026")
    print(SEPARATOR)

    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": LAST_MONTH_START, "End": LAST_MONTH_END},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    groups = resp["ResultsByTime"][0]["Groups"]
    services = [
        (g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"]))
        for g in groups
        if float(g["Metrics"]["UnblendedCost"]["Amount"]) > 0
    ]
    services.sort(key=lambda x: x[1], reverse=True)

    for svc, cost in services:
        bar = "█" * min(int(cost * 20), 40)
        print(f"  {fmt_usd(cost):>10}  {svc[:45]:<45}  {bar}")

    return services


# ── 3. Daily spend trend (anomaly detection) ──────────────────────────────────

def daily_trend_and_anomalies():
    print(f"\n{SEPARATOR}")
    print("  DAILY SPEND TREND — April 2026  (anomaly detection)")
    print(SEPARATOR)

    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": LAST_MONTH_START, "End": LAST_MONTH_END},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
    )

    daily = [
        (r["TimePeriod"]["Start"], float(r["Total"]["UnblendedCost"]["Amount"]))
        for r in resp["ResultsByTime"]
    ]

    costs   = [c for _, c in daily]
    avg     = sum(costs) / len(costs) if costs else 0
    std_dev = (sum((c - avg) ** 2 for c in costs) / len(costs)) ** 0.5 if costs else 0
    threshold = avg + 2 * std_dev   # 2-sigma anomaly threshold

    anomalies = []
    print(f"\n  Daily avg: {fmt_usd(avg)}  |  Std dev: {fmt_usd(std_dev)}  |  Anomaly threshold (2σ): {fmt_usd(threshold)}\n")

    for date, cost in daily:
        flag = ""
        if cost > threshold and threshold > 0:
            flag = "  ◀ ANOMALY"
            anomalies.append((date, cost))
        bar = "▓" * min(int(cost * 200), 50)
        print(f"  {date}  {fmt_usd(cost):>10}  {bar}{flag}")

    return anomalies, avg, threshold


# ── 4. CE native anomaly detection ───────────────────────────────────────────

def ce_anomaly_detection():
    print(f"\n{SEPARATOR}")
    print("  AWS COST ANOMALY DETECTION  (native CE anomalies)")
    print(SEPARATOR)

    try:
        # List anomaly monitors
        monitors_resp = ce.get_anomaly_monitors()
        monitors = monitors_resp.get("AnomalyMonitors", [])

        if not monitors:
            print("\n  ⚠️  No anomaly monitors configured.")
            print("     Tip: Enable Cost Anomaly Detection in the AWS Console")
            print("     (Billing → Cost Anomaly Detection → Create monitor)")
            return []

        all_anomalies = []
        for monitor in monitors:
            monitor_arn = monitor["MonitorArn"]
            monitor_name = monitor.get("MonitorName", monitor_arn)
            print(f"\n  Monitor: {monitor_name}")

            anomalies_resp = ce.get_anomalies(
                MonitorArn=monitor_arn,
                DateInterval={"StartDate": LAST_MONTH_START, "EndDate": LAST_MONTH_END},
            )
            anomalies = anomalies_resp.get("Anomalies", [])

            if not anomalies:
                print("  ✅ No anomalies detected for this monitor in April 2026")
            else:
                for a in anomalies:
                    impact   = a.get("Impact", {})
                    total_impact = float(impact.get("TotalImpact", 0))
                    max_impact   = float(impact.get("MaxImpact", 0))
                    start = a["AnomalyStartDate"]
                    end   = a.get("AnomalyEndDate", "ongoing")
                    score = a.get("AnomalyScore", {}).get("MaxScore", 0)
                    svc   = a.get("RootCauses", [{}])[0].get("Service", "Unknown")
                    region = a.get("RootCauses", [{}])[0].get("Region", "Unknown")

                    print(f"\n  🔴 Anomaly detected")
                    print(f"     Period       : {start} → {end}")
                    print(f"     Service      : {svc}  |  Region: {region}")
                    print(f"     Total impact : {fmt_usd(total_impact)}")
                    print(f"     Max daily    : {fmt_usd(max_impact)}")
                    print(f"     Score        : {score:.2f}")
                    all_anomalies.append(a)

        return all_anomalies

    except ce.exceptions.LimitExceededException as e:
        print(f"\n  ⚠️  Rate limited: {e}")
        return []
    except Exception as e:
        print(f"\n  ⚠️  Could not fetch CE anomalies: {e}")
        return []


# ── 5. Month-over-month comparison ───────────────────────────────────────────

def month_over_month(services_last_month):
    print(f"\n{SEPARATOR}")
    print("  MONTH-OVER-MONTH  (March vs April 2026)")
    print(SEPARATOR)

    try:
        resp_prev = ce.get_cost_and_usage(
            TimePeriod={"Start": "2026-03-01", "End": "2026-04-01"},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
        prev_map = {
            g["Keys"][0]: float(g["Metrics"]["UnblendedCost"]["Amount"])
            for g in resp_prev["ResultsByTime"][0]["Groups"]
        }

        curr_map = dict(services_last_month)
        all_svcs = sorted(set(list(prev_map.keys()) + list(curr_map.keys())))

        print(f"\n  {'Service':<45}  {'Mar':>10}  {'Apr':>10}  {'Δ':>8}")
        print(f"  {'-'*45}  {'-'*10}  {'-'*10}  {'-'*8}")

        for svc in all_svcs:
            prev = prev_map.get(svc, 0)
            curr = curr_map.get(svc, 0)
            if prev == 0 and curr == 0:
                continue
            if prev > 0:
                pct = ((curr - prev) / prev) * 100
                pct_str = f"{pct:+.1f}%"
            else:
                pct = None
                pct_str = "new"
            icon = delta_icon(pct)
            print(f"  {icon} {svc[:43]:<43}  {fmt_usd(prev):>10}  {fmt_usd(curr):>10}  {pct_str:>8}")

    except Exception as e:
        print(f"\n  ⚠️  Could not fetch March data: {e}")


# ── 6. Current month so far ───────────────────────────────────────────────────

def current_month_so_far():
    print(f"\n{SEPARATOR}")
    print(f"  MAY 2026 — SPEND SO FAR  ({THIS_MONTH_START} → {TODAY})")
    print(SEPARATOR)

    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": THIS_MONTH_START, "End": TODAY},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    groups = resp["ResultsByTime"][0]["Groups"]
    services = [
        (g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"]))
        for g in groups
        if float(g["Metrics"]["UnblendedCost"]["Amount"]) > 0
    ]
    services.sort(key=lambda x: x[1], reverse=True)

    total = sum(c for _, c in services)
    print(f"\n  Total so far : {fmt_usd(total)}")
    for svc, cost in services:
        print(f"  {fmt_usd(cost):>10}  {svc}")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"\n{'#' * 62}")
    print(f"  💰 CostAnalyzer Agent  —  AWS Cost Anomaly Report")
    print(f"  Account: {ACCOUNT_ID}  |  {now_str}")
    print(f"{'#' * 62}")

    total          = total_cost_last_month()
    services       = cost_by_service()
    anomalies, avg, threshold = daily_trend_and_anomalies()
    ce_anomalies   = ce_anomaly_detection()
    month_over_month(services)
    current_month_so_far()

    # ── Final verdict ──
    print(f"\n{SEPARATOR}")
    print("  ANOMALY SUMMARY")
    print(SEPARATOR)
    if anomalies:
        print(f"\n  🔴 {len(anomalies)} statistical anomaly(ies) detected (>2σ above daily avg of {fmt_usd(avg)}):")
        for date, cost in anomalies:
            print(f"     {date}  →  {fmt_usd(cost)}  (threshold: {fmt_usd(threshold)})")
    else:
        print(f"\n  ✅ No statistical anomalies detected in April 2026")
        print(f"     Daily spend stayed within 2σ of avg ({fmt_usd(avg)})")

    if ce_anomalies:
        print(f"\n  🔴 AWS native anomaly detection flagged {len(ce_anomalies)} event(s)")
    else:
        print(f"\n  ✅ AWS Cost Anomaly Detection: no events flagged")

    print(f"\n  Total April spend: {fmt_usd(total)}")
    print(f"\n{SEPARATOR}\n")
