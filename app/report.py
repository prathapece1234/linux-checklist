"""
Report blueprint — Report viewer and history.
Serves individual health check reports and lists report history per host.
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
    """View the latest report for a hostname."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        abort(404)

    # Find latest HTML report
    reports = sorted(
        [f for f in os.listdir(host_dir)
         if f.startswith("HealthCheck_") and f.endswith(".html") and f != "latest.html"],
        reverse=True,
    )

    if not reports:
        abort(404)

    return render_template(
        "report.html",
        hostname=hostname,
        filename=reports[0],
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )


@report_bp.route("/report/<hostname>/<filename>")
def view_report(hostname, filename):
    """View a specific report for a hostname."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    filepath = os.path.join(host_dir, filename)

    if not os.path.isfile(filepath):
        abort(404)

    return render_template(
        "report.html",
        hostname=hostname,
        filename=filename,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )


@report_bp.route("/reports/<hostname>/<filename>")
def serve_report_file(hostname, filename):
    """Serve the raw HTML report file (used by iframe)."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        abort(404)
    return send_from_directory(host_dir, filename)


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
            reports.append({
                "filename": f,
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
