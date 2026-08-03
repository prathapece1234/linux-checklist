"""
Upload API blueprint — Handles report uploads from health_check.sh agents.
Migrated from the standalone upload.py with no authentication required.
"""

import os
import re
import logging
from datetime import datetime

from flask import Blueprint, request, jsonify

from app.config import Config

upload_bp = Blueprint("upload_api", __name__)
logger = logging.getLogger(__name__)

ALLOWED_EXTENSIONS = {".html", ".htm", ".txt", ".json"}


def sanitize_hostname(hostname):
    """Sanitize hostname to prevent directory traversal."""
    if not hostname:
        return None
    sanitized = re.sub(r"[^a-zA-Z0-9._-]", "", hostname)
    sanitized = sanitized.strip(".")
    if not sanitized or sanitized in (".", ".."):
        return None
    return sanitized


def get_file_extension(filename):
    """Extract file extension."""
    if not filename:
        return None
    _, ext = os.path.splitext(filename)
    return ext.lower()


def generate_report_filename(hostname, original_filename):
    """Generate or preserve report filename for matching HTML, TXT, and JSON files."""
    ext = get_file_extension(original_filename) or ".html"
    base = os.path.basename(original_filename) if original_filename else ""
    if base.startswith("HealthCheck_"):
        return base
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    return f"HealthCheck_{hostname}_{timestamp}{ext}"


def create_latest_symlink(host_dir, report_filename):
    """Create/update latest.html symlink."""
    latest_link = os.path.join(host_dir, "latest.html")
    report_path = os.path.join(host_dir, report_filename)

    try:
        if os.path.islink(latest_link) or os.path.exists(latest_link):
            os.remove(latest_link)
        os.symlink(report_path, latest_link)
        logger.info("Updated latest.html symlink -> %s", report_filename)
    except OSError as e:
        logger.warning("Symlink failed (%s), copying file instead", e)
        try:
            import shutil
            shutil.copy2(report_path, latest_link)
        except Exception as copy_err:
            logger.error("Failed to create latest.html: %s", copy_err)


@upload_bp.route("/upload", methods=["POST"])
def upload_report():
    """Handle health check report uploads. No authentication required."""
    hostname = request.form.get("hostname", "").strip()
    sanitized_hostname = sanitize_hostname(hostname)

    if not sanitized_hostname:
        logger.warning("Upload rejected: invalid or missing hostname '%s'", hostname)
        return jsonify({"status": "error", "message": "Invalid or missing hostname"}), 400

    if "file" not in request.files:
        logger.warning("Upload rejected: no file field from %s", sanitized_hostname)
        return jsonify({"status": "error", "message": "No file provided"}), 400

    uploaded_file = request.files["file"]

    if not uploaded_file.filename:
        logger.warning("Upload rejected: empty filename from %s", sanitized_hostname)
        return jsonify({"status": "error", "message": "Empty filename"}), 400

    ext = get_file_extension(uploaded_file.filename)
    if ext not in ALLOWED_EXTENSIONS:
        logger.warning("Upload rejected: disallowed extension '%s' from %s", ext, sanitized_hostname)
        return jsonify({
            "status": "error",
            "message": f"File extension '{ext}' not allowed. Allowed: {', '.join(ALLOWED_EXTENSIONS)}",
        }), 400

    # Create host-specific directory
    web_root = Config.WEB_ROOT
    host_dir = os.path.join(web_root, sanitized_hostname)
    os.makedirs(host_dir, exist_ok=True)

    # Generate unique filename
    report_filename = generate_report_filename(sanitized_hostname, uploaded_file.filename)
    report_path = os.path.join(host_dir, report_filename)

    # Avoid overwrites
    counter = 1
    original = report_filename
    while os.path.exists(report_path):
        name, file_ext = os.path.splitext(original)
        report_filename = f"{name}_{counter}{file_ext}"
        report_path = os.path.join(host_dir, report_filename)
        counter += 1

    # Save the file
    try:
        uploaded_file.save(report_path)
        file_size = os.path.getsize(report_path)
        logger.info("Report saved: %s/%s (%d bytes) from %s",
                     sanitized_hostname, report_filename, file_size, request.remote_addr)
    except Exception as e:
        logger.error("Failed to save report: %s", e)
        return jsonify({"status": "error", "message": "Failed to save report"}), 500

    # Create latest symlink for HTML reports
    if ext in (".html", ".htm"):
        create_latest_symlink(host_dir, report_filename)

    response_data = {
        "status": "success",
        "message": "Upload Successful",
        "hostname": sanitized_hostname,
        "filename": report_filename,
        "size": file_size,
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }

    logger.info("Upload completed for %s: %s", sanitized_hostname, report_filename)
    return jsonify(response_data), 200


@upload_bp.route("/health", methods=["GET"])
def health():
    """API health check endpoint. No authentication required."""
    return "OK", 200


@upload_bp.route("/hosts", methods=["GET"])
def list_hosts():
    """List all hosts that have submitted reports. No authentication required."""
    web_root = Config.WEB_ROOT
    hosts = []

    if os.path.isdir(web_root):
        for entry in sorted(os.listdir(web_root)):
            host_dir = os.path.join(web_root, entry)
            if os.path.isdir(host_dir) and entry not in ("static", ".", ".."):
                reports = [f for f in os.listdir(host_dir)
                           if f.startswith("HealthCheck_") and f != "latest.html"]
                hosts.append({
                    "hostname": entry,
                    "report_count": len(reports),
                    "latest": os.path.exists(os.path.join(host_dir, "latest.html")),
                })

    return jsonify({"status": "success", "host_count": len(hosts), "hosts": hosts}), 200


@upload_bp.errorhandler(413)
def request_entity_too_large(error):
    """Handle file too large errors."""
    max_mb = Config.MAX_CONTENT_LENGTH // (1024 * 1024)
    return jsonify({"status": "error", "message": f"File too large. Maximum: {max_mb} MB"}), 413
