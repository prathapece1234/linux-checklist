"""
Dashboard blueprint — Dynamic server dashboard.
Scans WEB_ROOT for host directories and reads report metadata.
"""

import os
import re
import json
import logging
from datetime import datetime

from flask import Blueprint, render_template, session

from app.config import Config

dashboard_bp = Blueprint("dashboard", __name__)
logger = logging.getLogger(__name__)


def extract_meta_from_host(host_dir, latest_html_filename):
    """Extract metadata for a host from its JSON or HTML report files."""
    meta = {
        "hostname": "",
        "os": "",
        "ip": "",
        "date": "",
        "kernel": "",
        "status": "Healthy",
    }

    # 1. Try reading latest JSON report first
    json_files = sorted(
        [f for f in os.listdir(host_dir) if f.startswith("HealthCheck_") and f.endswith(".json")],
        reverse=True,
    )

    if json_files:
        json_path = os.path.join(host_dir, json_files[0])
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                sys_info = data.get("system", {})
                meta["hostname"] = sys_info.get("hostname", "")
                meta["os"] = sys_info.get("os", "")
                meta["ip"] = sys_info.get("ip", "")
                meta["kernel"] = sys_info.get("kernel", "")
        except Exception as e:
            logger.warning("Failed to parse JSON metadata %s: %s", json_path, e)

    # 2. Fallback / supplement from HTML report file
    if latest_html_filename:
        html_path = os.path.join(host_dir, latest_html_filename)
        try:
            with open(html_path, "r", encoding="utf-8", errors="ignore") as f:
                # Read up to 64KB to cover head + top navbar
                content = f.read(65536)

            patterns = {
                "hostname": r'<meta\s+name="report-hostname"\s+content="([^"]*)"',
                "os": r'<meta\s+name="report-os"\s+content="([^"]*)"',
                "ip": r'<meta\s+name="report-ip"\s+content="([^"]*)"',
                "date": r'<meta\s+name="report-date"\s+content="([^"]*)"',
                "kernel": r'<meta\s+name="report-kernel"\s+content="([^"]*)"',
            }

            for key, pattern in patterns.items():
                if not meta.get(key):
                    match = re.search(pattern, content, re.IGNORECASE)
                    if match:
                        meta[key] = match.group(1).strip()

            # Backup regex for kernel in top navbar HTML if not found
            if not meta["kernel"]:
                kernel_match = re.search(r'Kernel:</span>\s*<span>([^<]*)</span>', content, re.IGNORECASE)
                if kernel_match:
                    meta["kernel"] = kernel_match.group(1).strip()

        except Exception as e:
            logger.warning("Failed to extract metadata from HTML %s: %s", html_path, e)

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

        latest = reports[0]
        meta = extract_meta_from_host(host_dir, latest["filename"])

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
            "status": meta["status"] or "Healthy",
            "report_count": len(reports),
            "json_count": len(json_reports),
            "latest_report": latest["filename"],
        })

    return hosts


@dashboard_bp.route("/")
@dashboard_bp.route("/dashboard")
def index():
    """Render the dynamic dashboard."""
    hosts = get_hosts()
    total_reports = sum(h["report_count"] for h in hosts)

    # Calculate summary counts
    healthy_count = sum(1 for h in hosts if h["status"].lower() in ("healthy", "pass", "completed"))
    warning_count = sum(1 for h in hosts if h["status"].lower() in ("warning", "warn"))
    critical_count = sum(1 for h in hosts if h["status"].lower() in ("critical", "fail", "failed"))

    # Collect unique OS list for filter dropdown
    unique_os = sorted(set(h["os"] for h in hosts if h["os"] != "Unknown"))

    return render_template(
        "dashboard.html",
        hosts=hosts,
        total_servers=len(hosts),
        total_reports=total_reports,
        healthy_count=healthy_count,
        warning_count=warning_count,
        critical_count=critical_count,
        unique_os=unique_os,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )
