"""
Compare blueprint — Infrastructure Configuration Drift Engine.
Focuses on meaningful configuration drift (kernel, OS, mounts, services, IPs, security).
Ignores normal runtime fluctuations (uptime, memory %, swap %, CPU load, timestamps).
"""

import os
import json
import logging
from datetime import datetime

from flask import Blueprint, render_template, request, jsonify, abort, session, redirect, url_for

from app.config import Config

compare_bp = Blueprint("compare", __name__)
logger = logging.getLogger(__name__)


# =============================================================================
# JSON LOADING & REPORT DISCOVERY
# =============================================================================

def resolve_json_filename(filename):
    """Normalize input filename (.html, .txt, or .json) to .json."""
    if not filename:
        return ""
    base = os.path.splitext(filename)[0]
    return base + ".json"


def load_json(filepath):
    """
    Load and return a JSON summary file.
    Returns (data, error_message).
    """
    if not os.path.isfile(filepath):
        return None, f"File not found: {filepath}"

    file_size = os.path.getsize(filepath)
    if file_size == 0:
        return None, f"File is empty (0 bytes): {filepath}"

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
            if not isinstance(data, dict):
                return None, f"Invalid JSON structure (expected root dictionary): {filepath}"
            return data, None
    except json.JSONDecodeError as e:
        logger.error("JSON decode error in %s: %s", filepath, e)
        return None, f"Invalid JSON syntax at line {e.lineno}, column {e.colno}: {e.msg}"
    except Exception as e:
        logger.error("Failed to load JSON %s: %s", filepath, e)
        return None, f"Unexpected error reading file: {str(e)}"


def get_json_reports(hostname):
    """Get all JSON reports for a hostname sorted newest-first."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        return []

    reports = []
    seen = set()
    for f in sorted(os.listdir(host_dir), reverse=True):
        if f.startswith("HealthCheck_") and f != "latest.html":
            json_file = resolve_json_filename(f)
            if json_file in seen:
                continue

            json_path = os.path.join(host_dir, json_file)
            if os.path.isfile(json_path):
                seen.add(json_file)
                mtime = os.path.getmtime(json_path)
                reports.append({
                    "filename": json_file,
                    "mtime": mtime,
                    "mtime_str": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S"),
                    "size_kb": round(os.path.getsize(json_path) / 1024, 1),
                })

    return reports


# =============================================================================
# CONFIGURATION DRIFT COMPARISON ENGINE
# =============================================================================

def compare_system(old, new):
    """Compare System specs (Hostname, OS, Kernel, Cores). Uptime is Info-only."""
    results = []
    sys_old = old.get("system", {})
    sys_new = new.get("system", {})

    drift_fields = [
        ("Hostname", "hostname"),
        ("FQDN", "fqdn"),
        ("Operating System", "os"),
        ("Kernel Version", "kernel"),
        ("CPU Cores", "cpu_cores"),
        ("Total RAM", "ram_total"),
    ]

    for label, key in drift_fields:
        old_val = str(sys_old.get(key, "N/A")).strip()
        new_val = str(sys_new.get(key, "N/A")).strip()
        changed = old_val != new_val
        results.append({
            "item": label,
            "previous": old_val,
            "current": new_val,
            "status": "CHANGED" if changed else "NO_CHANGE",
            "is_drift": changed,
            "type": "text",
        })

    # Uptime is informational only (never marked as drift)
    old_upt = str(sys_old.get("uptime", "N/A")).strip()
    new_upt = str(sys_new.get("uptime", "N/A")).strip()
    results.append({
        "item": "System Uptime",
        "previous": old_upt,
        "current": new_upt,
        "status": "INFO",
        "is_drift": False,
        "type": "text",
    })

    return results


def compare_storage(old, new):
    """Compare Mount Point structure (Mount added, removed, or retained). Usage % is Info-only."""
    results = []
    fs_old = {item["mount"]: item for item in old.get("storage", {}).get("filesystems", []) if "mount" in item}
    fs_new = {item["mount"]: item for item in new.get("storage", {}).get("filesystems", []) if "mount" in item}

    all_mounts = sorted(set(list(fs_old.keys()) + list(fs_new.keys())))

    for mount in all_mounts:
        old_entry = fs_old.get(mount)
        new_entry = fs_new.get(mount)

        if old_entry and not new_entry:
            results.append({
                "item": f"Mount Point {mount}",
                "previous": f"{old_entry.get('filesystem', 'dev')} ({old_entry.get('size', 'N/A')})",
                "current": "Mount Removed",
                "status": "REMOVED",
                "is_drift": True,
                "type": "text",
            })
        elif not old_entry and new_entry:
            results.append({
                "item": f"Mount Point {mount}",
                "previous": "Not Mounted",
                "current": f"{new_entry.get('filesystem', 'dev')} ({new_entry.get('size', 'N/A')})",
                "status": "ADDED",
                "is_drift": True,
                "type": "text",
            })
        else:
            old_str = f"{old_entry.get('used', 'N/A')}/{old_entry.get('size', 'N/A')} ({old_entry.get('use_pct', '0%')})"
            new_str = f"{new_entry.get('used', 'N/A')}/{new_entry.get('size', 'N/A')} ({new_entry.get('use_pct', '0%')})"
            results.append({
                "item": f"Mount Point {mount}",
                "previous": old_str,
                "current": new_str,
                "status": "NO_CHANGE",
                "is_drift": False,
                "type": "text",
            })

    return results


def compare_memory(old, new):
    """Memory & Swap usage fluctuate naturally. Displayed for reference only (is_drift = False)."""
    results = []
    mem_old = old.get("memory", {})
    mem_new = new.get("memory", {})

    ram_old_pct = mem_old.get("ram_used_pct", "N/A")
    ram_new_pct = mem_new.get("ram_used_pct", "N/A")
    ram_old_str = f"{mem_old.get('ram_used', 'N/A')} / {mem_old.get('ram_total', 'N/A')} ({ram_old_pct})"
    ram_new_str = f"{mem_new.get('ram_used', 'N/A')} / {mem_new.get('ram_total', 'N/A')} ({ram_new_pct})"

    results.append({
        "item": "RAM Memory Utilization",
        "previous": ram_old_str,
        "current": ram_new_str,
        "status": "INFO",
        "is_drift": False,
        "type": "text",
    })

    swap_old_pct = mem_old.get("swap_used_pct", "N/A")
    swap_new_pct = mem_new.get("swap_used_pct", "N/A")
    swap_old_str = f"{mem_old.get('swap_used', 'N/A')} / {mem_old.get('swap_total', 'N/A')} ({swap_old_pct})"
    swap_new_str = f"{mem_new.get('swap_used', 'N/A')} / {mem_new.get('swap_total', 'N/A')} ({swap_new_pct})"

    results.append({
        "item": "Swap Memory Utilization",
        "previous": swap_old_str,
        "current": swap_new_str,
        "status": "INFO",
        "is_drift": False,
        "type": "text",
    })

    return results


def compare_services(old, new):
    """Compare Service State (Running, Stopped, Failed, Not Installed). Ignore logs/timestamps."""
    results = []
    svc_old = old.get("services", {})
    svc_new = new.get("services", {})

    target_services = ["sshd", "docker", "nginx", "chronyd", "multipathd", "rsyslog"]
    all_services = sorted(set(target_services + list(svc_old.keys()) + list(svc_new.keys())))

    for svc in all_services:
        old_st = str(svc_old.get(svc, "NOT_INSTALLED")).strip().upper()
        new_st = str(svc_new.get(svc, "NOT_INSTALLED")).strip().upper()

        if old_st in ("N/A", "UNKNOWN", ""): old_st = "NOT_INSTALLED"
        if new_st in ("N/A", "UNKNOWN", ""): new_st = "NOT_INSTALLED"

        # If both are NOT_INSTALLED -> NO_CHANGE (not drift)
        if old_st == "NOT_INSTALLED" and new_st == "NOT_INSTALLED":
            results.append({
                "item": f"Service: {svc}",
                "previous": "Not Installed",
                "current": "Not Installed",
                "status": "NO_CHANGE",
                "is_drift": False,
                "type": "text",
            })
        elif old_st != new_st:
            results.append({
                "item": f"Service: {svc}",
                "previous": old_st.title(),
                "current": new_st.title(),
                "status": "CHANGED",
                "is_drift": True,
                "type": "text",
            })
        else:
            results.append({
                "item": f"Service: {svc}",
                "previous": old_st.title(),
                "current": new_st.title(),
                "status": "NO_CHANGE",
                "is_drift": False,
                "type": "text",
            })

    return results


def compare_network(old, new):
    """Compare Network configuration (IP Addresses & Routes)."""
    results = []
    net_old = old.get("network", {})
    net_new = new.get("network", {})

    old_ips = ", ".join(net_old.get("ip_addresses", [])) or "None"
    new_ips = ", ".join(net_new.get("ip_addresses", [])) or "None"
    ip_changed = old_ips != new_ips

    results.append({
        "item": "Configured IP Addresses",
        "previous": old_ips,
        "current": new_ips,
        "status": "CHANGED" if ip_changed else "NO_CHANGE",
        "is_drift": ip_changed,
        "type": "text",
    })

    old_routes = len(net_old.get("routes", []))
    new_routes = len(net_new.get("routes", []))
    route_changed = old_routes != new_routes

    results.append({
        "item": "Network Routing Rules",
        "previous": f"{old_routes} routes active",
        "current": f"{new_routes} routes active",
        "status": "CHANGED" if route_changed else "NO_CHANGE",
        "is_drift": route_changed,
        "type": "text",
    })

    return results


def compare_security(old, new):
    """Compare Security Settings (SELinux, NTP Sync)."""
    results = []
    sec_old = old.get("security", {})
    sec_new = new.get("security", {})

    old_sel = str(sec_old.get("selinux", "Disabled")).strip()
    new_sel = str(sec_new.get("selinux", "Disabled")).strip()
    sel_changed = old_sel != new_sel

    results.append({
        "item": "SELinux Mode",
        "previous": old_sel,
        "current": new_sel,
        "status": "CHANGED" if sel_changed else "NO_CHANGE",
        "is_drift": sel_changed,
        "type": "text",
    })

    old_ntp = str(sec_old.get("ntp", "Not Synchronized")).strip()
    new_ntp = str(sec_new.get("ntp", "Not Synchronized")).strip()
    ntp_changed = old_ntp != new_ntp

    results.append({
        "item": "NTP Time Synchronization",
        "previous": old_ntp,
        "current": new_ntp,
        "status": "CHANGED" if ntp_changed else "NO_CHANGE",
        "is_drift": ntp_changed,
        "type": "text",
    })

    return results


def generate_summary(categories, report_old_time, report_new_time):
    """Calculate meaningful configuration drift summary statistics."""
    drift_count = 0
    total_evaluated = 0

    for cat_results in categories.values():
        for item in cat_results:
            total_evaluated += 1
            if item.get("is_drift", False):
                drift_count += 1

    overall = "HEALTHY" if drift_count == 0 else "CHANGED"

    return {
        "overall": overall,
        "drift_count": drift_count,
        "total_evaluated": total_evaluated,
        "report_old_time": report_old_time,
        "report_new_time": report_new_time,
    }


# =============================================================================
# ROUTES
# =============================================================================

@compare_bp.route("/compare/<hostname>", methods=["GET", "POST"])
@compare_bp.route("/compare/<hostname>/run", methods=["GET", "POST"])
def compare_page(hostname):
    """Unified route handling comparison GET and POST. Never returns blank page."""
    host_dir = os.path.join(Config.WEB_ROOT, hostname)
    if not os.path.isdir(host_dir):
        logger.warning("Compare requested for non-existent host directory: %s", hostname)
        abort(404)

    reports = get_json_reports(hostname)

    raw_old = request.form.get("report_old") or request.args.get("report_old")
    raw_new = request.form.get("report_new") or request.args.get("report_new")

    report_old = resolve_json_filename(raw_old) if raw_old else None
    report_new = resolve_json_filename(raw_new) if raw_new else None

    # Auto-select latest (new) and 2nd latest (old) if not specified
    if len(reports) >= 2:
        if not report_new:
            report_new = reports[0]["filename"]
        if not report_old:
            report_old = reports[1]["filename"]

    categories = None
    summary = None
    error_msg = None

    # Resolve timestamps for header card
    old_time_str = "N/A"
    new_time_str = "N/A"

    for r in reports:
        if r["filename"] == report_old:
            old_time_str = r["mtime_str"]
        if r["filename"] == report_new:
            new_time_str = r["mtime_str"]

    if len(reports) < 2:
        error_msg = "At least two JSON health reports are required to perform a Before vs After activity comparison."
    elif report_old and report_new:
        old_path = os.path.join(host_dir, report_old)
        new_path = os.path.join(host_dir, report_new)

        old_data, old_err = load_json(old_path)
        new_data, new_err = load_json(new_path)

        if old_data and new_data:
            categories = {
                "System & Operating System": compare_system(old_data, new_data),
                "Storage & Mount Structure": compare_storage(old_data, new_data),
                "Key Infrastructure Services": compare_services(old_data, new_data),
                "Network & Routing Rules": compare_network(old_data, new_data),
                "Security & Time Sync": compare_security(old_data, new_data),
                "Memory & Swap Utilization (Informational)": compare_memory(old_data, new_data),
            }
            summary = generate_summary(categories, old_time_str, new_time_str)
        else:
            err_details = []
            if old_err: err_details.append(f"Previous Report ({report_old}): {old_err}")
            if new_err: err_details.append(f"Current Report ({report_new}): {new_err}")
            error_msg = "Unable to parse report files.\n" + "\n".join(err_details)

    return render_template(
        "compare.html",
        hostname=hostname,
        json_reports=reports,
        results=categories,
        summary=summary,
        report_old=report_old,
        report_new=report_new,
        error_msg=error_msg,
        user=session.get("user"),
        auth_enabled=Config.AUTH_ENABLED,
    )
