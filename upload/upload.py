#!/usr/bin/env python3
# =============================================================================
# Enterprise Linux Health Dashboard - Flask Upload API
# =============================================================================
# Receives health check reports uploaded via curl from production servers.
# Stores reports under /var/www/html/health-reports/<hostname>/ with history.
# Triggers dashboard regeneration after each successful upload.
#
# API Endpoint:
#   POST /upload
#   Fields: hostname (text), file (multipart file)
#
# Usage:
#   python3 upload.py
#   Or via systemd service: systemctl start health-dashboard-api
# =============================================================================

import os
import sys
import logging
import subprocess
import re
from datetime import datetime
from flask import Flask, request, jsonify

# =============================================================================
# CONFIGURATION
# =============================================================================

# Base directory for storing reports
WEB_ROOT = os.environ.get("WEB_ROOT", "/var/www/html/health-reports")

# Flask listen configuration
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "5000"))

# Maximum upload size (50 MB)
MAX_CONTENT_LENGTH = 50 * 1024 * 1024

# Path to the dashboard generator script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_GENERATOR = os.path.join(SCRIPT_DIR, "generate_dashboard.py")

# Allowed file extensions
ALLOWED_EXTENSIONS = {".html", ".htm", ".txt"}

# =============================================================================
# APPLICATION SETUP
# =============================================================================

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_CONTENT_LENGTH

log_dir = "/var/log/health-dashboard"
log_file = os.path.join(log_dir, "upload.log")
handlers = [logging.StreamHandler(sys.stdout)]

if os.path.isdir(log_dir):
    try:
        handlers.append(logging.FileHandler(log_file, mode="a"))
    except Exception:
        pass

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=handlers,
)
logger = logging.getLogger(__name__)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================


def sanitize_hostname(hostname):
    """
    Sanitize hostname to prevent directory traversal and invalid characters.
    Only allow alphanumeric, hyphens, underscores, and dots.
    """
    if not hostname:
        return None
    # Remove any path separators and dangerous characters
    sanitized = re.sub(r"[^a-zA-Z0-9._-]", "", hostname)
    # Prevent directory traversal
    sanitized = sanitized.strip(".")
    if not sanitized or sanitized in (".", ".."):
        return None
    return sanitized


def get_file_extension(filename):
    """Extract and validate file extension."""
    if not filename:
        return None
    _, ext = os.path.splitext(filename)
    return ext.lower()


def ensure_directory(path):
    """Create directory if it doesn't exist."""
    os.makedirs(path, exist_ok=True)


def generate_report_filename(hostname, original_filename):
    """
    Generate a unique timestamped filename for the report.
    Format: HealthCheck_<hostname>_<timestamp>.<ext>
    """
    ext = get_file_extension(original_filename) or ".html"
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    return f"HealthCheck_{hostname}_{timestamp}{ext}"


def create_latest_symlink(host_dir, report_filename):
    """
    Create/update a 'latest.html' symlink pointing to the newest report.
    """
    latest_link = os.path.join(host_dir, "latest.html")
    report_path = os.path.join(host_dir, report_filename)

    try:
        # Remove existing symlink or file
        if os.path.islink(latest_link) or os.path.exists(latest_link):
            os.remove(latest_link)
        os.symlink(report_path, latest_link)
        logger.info("Updated latest.html symlink -> %s", report_filename)
    except OSError as e:
        # Fallback: copy the file instead of symlink (Windows compatibility)
        logger.warning("Symlink failed (%s), copying file instead", e)
        try:
            import shutil
            shutil.copy2(report_path, latest_link)
        except Exception as copy_err:
            logger.error("Failed to create latest.html: %s", copy_err)


def trigger_dashboard_rebuild():
    """
    Execute the dashboard generator script to rebuild index.html.
    """
    if not os.path.isfile(DASHBOARD_GENERATOR):
        logger.error("Dashboard generator not found: %s", DASHBOARD_GENERATOR)
        return False

    try:
        result = subprocess.run(
            [sys.executable, DASHBOARD_GENERATOR, WEB_ROOT],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            logger.info("Dashboard rebuilt successfully")
            return True
        else:
            logger.error("Dashboard rebuild failed: %s", result.stderr)
            return False
    except subprocess.TimeoutExpired:
        logger.error("Dashboard rebuild timed out")
        return False
    except Exception as e:
        logger.error("Dashboard rebuild error: %s", e)
        return False


# =============================================================================
# API ROUTES
# =============================================================================


@app.route("/upload", methods=["POST"])
def upload_report():
    """
    Handle health check report uploads.

    Expected form fields:
        hostname: Server hostname (text)
        file: Report file (multipart file upload)

    Returns:
        JSON response with upload status.
    """
    # Validate hostname field
    hostname = request.form.get("hostname", "").strip()
    sanitized_hostname = sanitize_hostname(hostname)

    if not sanitized_hostname:
        logger.warning("Upload rejected: invalid or missing hostname '%s'", hostname)
        return jsonify({
            "status": "error",
            "message": "Invalid or missing hostname",
        }), 400

    # Validate file field
    if "file" not in request.files:
        logger.warning("Upload rejected: no file field in request from %s", sanitized_hostname)
        return jsonify({
            "status": "error",
            "message": "No file provided",
        }), 400

    uploaded_file = request.files["file"]

    if not uploaded_file.filename:
        logger.warning("Upload rejected: empty filename from %s", sanitized_hostname)
        return jsonify({
            "status": "error",
            "message": "Empty filename",
        }), 400

    # Validate file extension
    ext = get_file_extension(uploaded_file.filename)
    if ext not in ALLOWED_EXTENSIONS:
        logger.warning(
            "Upload rejected: disallowed extension '%s' from %s",
            ext, sanitized_hostname,
        )
        return jsonify({
            "status": "error",
            "message": f"File extension '{ext}' not allowed. Allowed: {', '.join(ALLOWED_EXTENSIONS)}",
        }), 400

    # Create host-specific directory
    host_dir = os.path.join(WEB_ROOT, sanitized_hostname)
    ensure_directory(host_dir)

    # Generate unique filename (never overwrite)
    report_filename = generate_report_filename(sanitized_hostname, uploaded_file.filename)
    report_path = os.path.join(host_dir, report_filename)

    # Ensure we don't overwrite (edge case: same-second upload)
    counter = 1
    original_report_filename = report_filename
    while os.path.exists(report_path):
        name, file_ext = os.path.splitext(original_report_filename)
        report_filename = f"{name}_{counter}{file_ext}"
        report_path = os.path.join(host_dir, report_filename)
        counter += 1

    # Save the file
    try:
        uploaded_file.save(report_path)
        file_size = os.path.getsize(report_path)
        logger.info(
            "Report saved: %s/%s (%d bytes) from %s",
            sanitized_hostname, report_filename, file_size,
            request.remote_addr,
        )
    except Exception as e:
        logger.error("Failed to save report: %s", e)
        return jsonify({
            "status": "error",
            "message": "Failed to save report",
        }), 500

    # Create latest symlink
    create_latest_symlink(host_dir, report_filename)

    # Trigger dashboard rebuild
    dashboard_rebuilt = trigger_dashboard_rebuild()

    response_data = {
        "status": "success",
        "message": "Upload Successful",
        "hostname": sanitized_hostname,
        "filename": report_filename,
        "size": file_size,
        "dashboard_updated": dashboard_rebuilt,
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }

    logger.info("Upload completed for %s: %s", sanitized_hostname, report_filename)
    return jsonify(response_data), 200


@app.route("/health", methods=["GET"])
def health_check():
    """API health check endpoint."""
    return jsonify({
        "status": "healthy",
        "service": "Enterprise Linux Health Dashboard API",
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "web_root": WEB_ROOT,
    }), 200


@app.route("/hosts", methods=["GET"])
def list_hosts():
    """List all hosts that have submitted reports."""
    hosts = []
    if os.path.isdir(WEB_ROOT):
        for entry in sorted(os.listdir(WEB_ROOT)):
            host_dir = os.path.join(WEB_ROOT, entry)
            if os.path.isdir(host_dir) and entry not in ("static", ".", ".."):
                reports = [
                    f for f in os.listdir(host_dir)
                    if f.startswith("HealthCheck_") and not f == "latest.html"
                ]
                hosts.append({
                    "hostname": entry,
                    "report_count": len(reports),
                    "latest": os.path.exists(os.path.join(host_dir, "latest.html")),
                })

    return jsonify({
        "status": "success",
        "host_count": len(hosts),
        "hosts": hosts,
    }), 200


# =============================================================================
# ERROR HANDLERS
# =============================================================================


@app.errorhandler(413)
def request_entity_too_large(error):
    """Handle file too large errors."""
    logger.warning("Upload rejected: file too large")
    return jsonify({
        "status": "error",
        "message": f"File too large. Maximum size: {MAX_CONTENT_LENGTH // (1024 * 1024)} MB",
    }), 413


@app.errorhandler(404)
def not_found(error):
    """Handle 404 errors."""
    return jsonify({
        "status": "error",
        "message": "Endpoint not found",
    }), 404


@app.errorhandler(500)
def internal_error(error):
    """Handle 500 errors."""
    logger.error("Internal server error: %s", error)
    return jsonify({
        "status": "error",
        "message": "Internal server error",
    }), 500


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    # Ensure web root exists
    ensure_directory(WEB_ROOT)
    ensure_directory(os.path.join(WEB_ROOT, "static"))

    logger.info("=" * 60)
    logger.info("Enterprise Linux Health Dashboard - Upload API")
    logger.info("=" * 60)
    logger.info("Listening on %s:%d", LISTEN_HOST, LISTEN_PORT)
    logger.info("Web root: %s", WEB_ROOT)
    logger.info("Dashboard generator: %s", DASHBOARD_GENERATOR)
    logger.info("=" * 60)

    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
