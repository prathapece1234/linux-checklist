"""
Dashboard blueprint — Dynamic server cards dashboard.
Scans WEB_ROOT for host directories and reads report metadata.
"""

import os
import re
import logging
from datetime import datetime

from flask import Blueprint, render_template, session

from app.config import Config

dashboard_bp = Blueprint("dashboard", __name__)
logger = logging.getLogger(__name__)


def extract_meta_from_html(filepath):
    """Extract metadata from HTML report <meta> tags."""
    meta = {
        "hostname": "",
        "os": "",
        "ip": "",
        "date": "",
        "kernel": "",
        "status": "COMPLETED",
    }

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            head_content = f.read(5120)

        patterns = {
            "hostname": r'<meta\s+name="report-hostname"\s+content="([^"]*)"',
            "os": r'<meta\s+name="report-os"\s+content="([^"]*)"',
            "ip": r'<meta\s+name="report-ip"\s+content="([^"]*)"',
            "date": r'<meta\s+name="report-date"\s+content="([^"]*)"',
        }

        for key, pattern in patterns.items():
            match = re.search(pattern, head_content, re.IGNORECASE)
            if match:
                meta[key] = match.group(1).strip()

        # Extract kernel from nav bar content
        kernel_match = re.search(r'Kernel:</span>\s*<span>([^<]*)</span>', head_content)
        if kernel_match:
            meta["kernel"] = kernel_match.group(1).strip()

    except Exception as e:
        logger.warning("Failed to extract metadata from %s: %s", filepath, e)

    return meta


def get_hosts():
    """Scan WEB_ROOT and build host information list."""
    web_root = Config.WEB_ROOT
    hosts = []

    if not os.path.isdir(web_root):
        return hosts

    for entry in sorted(os.listdir(web_root)):
        host_dir = os.path.join(web_root, entry)
        if not os.path.isdir(host_dir) or entry in ("static", ".", ".."):
            continue

        # Collect all health check reports
        reports = []
        for f in sorted(os.listdir(host_dir), reverse=True):
            if f.startswith("HealthCheck_") and f.endswith(".html") and f != "latest.html":
                fpath = os.path.join(host_dir, f)
                mtime = os.path.getmtime(fpath)
                reports.append({
                    "filename": f,
                    "mtime": mtime,
                    "mtime_str": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S"),
                    "size": os.path.getsize(fpath),
                })

        if not reports:
            continue

        # Extract metadata from latest report
        latest = reports[0]
        latest_path = os.path.join(host_dir, latest["filename"])
        meta = extract_meta_from_html(latest_path)

        # Count JSON reports available for comparison
        json_reports = [f for f in os.listdir(host_dir)
                        if f.startswith("HealthCheck_") and f.endswith(".json")]

        hosts.append({
            "dirname": entry,
            "hostname": meta["hostname"] or entry,
            "os": meta["os"] or "Unknown",
            "ip": meta["ip"] or "N/A",
            "kernel": meta["kernel"] or "N/A",
            "last_scan": latest["mtime_str"],
            "last_scan_ts": latest["mtime"],
            "status": meta["status"],
            "report_count": len(reports),
            "json_count": len(json_reports),
            "latest_report": latest["filename"],
        })

    return hosts


@dashboard_bp.route("/")
@dashboard_bp.route("/dashboard")
def index():
    """Render the dynamic dashboard with server cards."""
    hosts = get_hosts()
    total_reports = sum(h["report_count"] for h in hosts)

    return render_template(
        "dashboard.html",
        hosts=hosts,
        total_servers=len(hosts),
        total_reports=total_reports,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )
