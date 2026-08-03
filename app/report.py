"""
Report blueprint — Report viewer and history.
Serves individual health check reports as full pages and lists report history per host.
"""

import os
import logging
from datetime import datetime

from flask import Blueprint, render_template, send_from_directory, abort, session

from app.config import Config

report_bp = Blueprint("report", __name__)
logger = logging.getLogger(__name__)


@report_bp.route("/report/<hostname>")
def view_latest(hostname):
    """View the latest HTML report for a hostname as a full page."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        abort(404)

    reports = sorted(
        [f for f in os.listdir(host_dir)
         if f.startswith("HealthCheck_") and f.endswith(".html") and f != "latest.html"],
        reverse=True,
    )

    if not reports:
        abort(404)

    return send_from_directory(host_dir, reports[0])


@report_bp.route("/report/<hostname>/<filename>")
def view_report(hostname, filename):
    """View a specific HTML report for a hostname as a full page."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    filepath = os.path.join(host_dir, filename)

    if not os.path.isfile(filepath):
        abort(404)

    return send_from_directory(host_dir, filename)


@report_bp.route("/raw-txt/<hostname>/<filename>")
def view_raw_txt(hostname, filename):
    """View raw TXT report output inside formatted <pre> block."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    # Ensure filename ends with .txt
    txt_filename = os.path.splitext(filename)[0] + ".txt"
    filepath = os.path.join(host_dir, txt_filename)

    if not os.path.isfile(filepath):
        abort(404)

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception as e:
        logger.error("Failed to read TXT report %s: %s", filepath, e)
        abort(500)

    size_kb = round(os.path.getsize(filepath) / 1024, 1)

    return render_template(
        "raw_view.html",
        title="Raw TXT Health Report",
        hostname=hostname,
        filename=txt_filename,
        content=content,
        size_kb=size_kb,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )


@report_bp.route("/raw-json/<hostname>/<filename>")
def view_raw_json(hostname, filename):
    """View raw JSON summary report output inside formatted <pre> block."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    json_filename = os.path.splitext(filename)[0] + ".json"
    filepath = os.path.join(host_dir, json_filename)

    if not os.path.isfile(filepath):
        abort(404)

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception as e:
        logger.error("Failed to read JSON report %s: %s", filepath, e)
        abort(500)

    size_kb = round(os.path.getsize(filepath) / 1024, 1)

    return render_template(
        "raw_view.html",
        title="Raw JSON Summary Report",
        hostname=hostname,
        filename=json_filename,
        content=content,
        size_kb=size_kb,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )


@report_bp.route("/history/<hostname>")
def history(hostname):
    """Show all reports for a hostname sorted by date."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        abort(404)

    reports = []
    for f in sorted(os.listdir(host_dir), reverse=True):
        if f.startswith("HealthCheck_") and f.endswith(".html") and f != "latest.html":
            fpath = os.path.join(host_dir, f)
            mtime = os.path.getmtime(fpath)
            
            # Match TXT report file
            base_name = os.path.splitext(f)[0]
            txt_filename = base_name + ".txt"
            txt_filepath = os.path.join(host_dir, txt_filename)
            has_txt = os.path.isfile(txt_filepath)

            reports.append({
                "filename": f,
                "txt_filename": txt_filename if has_txt else None,
                "has_txt": has_txt,
                "mtime": mtime,
                "mtime_str": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S"),
                "size": os.path.getsize(fpath),
                "size_kb": round(os.path.getsize(fpath) / 1024, 1),
            })

    return render_template(
        "history.html",
        hostname=hostname,
        reports=reports,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )


@report_bp.route("/download/<hostname>/<filename>")
def download_report(hostname, filename):
    """Download a report file."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        abort(404)
    return send_from_directory(host_dir, filename, as_attachment=True)
