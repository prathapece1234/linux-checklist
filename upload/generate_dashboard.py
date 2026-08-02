#!/usr/bin/env python3
# =============================================================================
# Enterprise Linux Health Dashboard - Dashboard Generator
# =============================================================================
# Scans the health reports directory and generates a static index.html
# dashboard page. Called automatically after each upload by upload.py,
# or can be run manually.
#
# Usage:
#   python3 generate_dashboard.py [web_root_path]
#   python3 generate_dashboard.py /var/www/html/health-reports
# =============================================================================

import os
import sys
import re
import logging
from datetime import datetime
from html import escape as html_escape

# =============================================================================
# CONFIGURATION
# =============================================================================

DEFAULT_WEB_ROOT = "/var/www/html/health-reports"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# =============================================================================
# REPORT METADATA EXTRACTION
# =============================================================================


def extract_meta_from_html(filepath):
    """
    Extract metadata from HTML report meta tags.
    Looks for meta tags: report-hostname, report-os, report-ip, report-date, report-status
    """
    meta = {
        "hostname": "",
        "os": "",
        "ip": "",
        "date": "",
        "status": "UNKNOWN",
    }

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            # Read only the first 5KB for meta tags (they're in the <head>)
            head_content = f.read(5120)

        # Extract meta tags
        meta_patterns = {
            "hostname": r'<meta\s+name="report-hostname"\s+content="([^"]*)"',
            "os": r'<meta\s+name="report-os"\s+content="([^"]*)"',
            "ip": r'<meta\s+name="report-ip"\s+content="([^"]*)"',
            "date": r'<meta\s+name="report-date"\s+content="([^"]*)"',
            "status": r'<meta\s+name="report-status"\s+content="([^"]*)"',
        }

        for key, pattern in meta_patterns.items():
            match = re.search(pattern, head_content, re.IGNORECASE)
            if match:
                meta[key] = match.group(1).strip()

        # Fallback: extract status from badge count if meta not found
        if meta["status"] in ("UNKNOWN", "PLACEHOLDER_STATUS", ""):
            if "badge-fail" in head_content:
                meta["status"] = "FAIL"
            elif "badge-warning" in head_content:
                meta["status"] = "WARNING"
            else:
                meta["status"] = "PASS"

    except Exception as e:
        logger.warning("Failed to extract metadata from %s: %s", filepath, e)

    return meta


def get_file_mtime(filepath):
    """Get file modification time as formatted string."""
    try:
        mtime = os.path.getmtime(filepath)
        return datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return "Unknown"


def scan_reports(web_root):
    """
    Scan the web root directory for all host report directories.
    Returns a list of host info dictionaries sorted by hostname.
    """
    hosts = []

    if not os.path.isdir(web_root):
        logger.error("Web root directory not found: %s", web_root)
        return hosts

    for entry in sorted(os.listdir(web_root)):
        host_dir = os.path.join(web_root, entry)

        # Skip non-directories and special directories
        if not os.path.isdir(host_dir):
            continue
        if entry in ("static", ".", ".."):
            continue

        # Find all health check reports
        reports = []
        for filename in sorted(os.listdir(host_dir), reverse=True):
            filepath = os.path.join(host_dir, filename)
            if filename.startswith("HealthCheck_") and filename.endswith((".html", ".htm")):
                reports.append({
                    "filename": filename,
                    "filepath": filepath,
                    "mtime": get_file_mtime(filepath),
                    "url": f"{entry}/{filename}",
                })

        if not reports:
            continue

        # Get metadata from the latest report
        latest_report = reports[0]  # Already sorted reverse by name (timestamp)
        latest_path = latest_report["filepath"]

        # Check if latest.html symlink/file exists
        latest_link = os.path.join(host_dir, "latest.html")
        if os.path.exists(latest_link):
            latest_path = latest_link
            latest_report["url"] = f"{entry}/latest.html"

        meta = extract_meta_from_html(latest_path)

        host_info = {
            "hostname": meta["hostname"] or entry,
            "dirname": entry,
            "os": meta["os"] or "Unknown",
            "ip": meta["ip"] or "N/A",
            "status": "COMPLETED",
            "latest_time": latest_report["mtime"],
            "latest_url": latest_report["url"],
            "report_count": len(reports),
            "reports": reports,
        }

        hosts.append(host_info)
        logger.info(
            "Found host: %s (%s) - %d reports - Status: %s",
            host_info["hostname"], host_info["os"],
            host_info["report_count"], host_info["status"],
        )

    return hosts


# =============================================================================
# DASHBOARD HTML GENERATION
# =============================================================================


def generate_status_badge(status):
    """Generate HTML badge for a status value."""
    status = status.upper()
    badge_map = {
        "PASS": ("badge-pass", "PASS"),
        "WARNING": ("badge-warn", "WARNING"),
        "FAIL": ("badge-fail", "FAIL"),
    }
    css_class, label = badge_map.get(status, ("badge-unknown", status))
    return f'<span class="status-badge {css_class}">{label}</span>'


def generate_history_modal(host):
    """Generate HTML for the report history modal."""
    hostname_escaped = html_escape(host["hostname"])
    rows = ""
    for i, report in enumerate(host["reports"][:20], 1):  # Limit to 20 entries
        rows += f"""
                <tr>
                    <td>{i}</td>
                    <td>{html_escape(report['filename'])}</td>
                    <td>{report['mtime']}</td>
                    <td><a href="{report['url']}" target="_blank" class="btn-view-sm">View</a></td>
                </tr>"""

    return f"""
    <div class="modal-overlay" id="modal-{host['dirname']}" onclick="closeModal('{host['dirname']}')">
        <div class="modal-content" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h3>Report History: {hostname_escaped}</h3>
                <button class="modal-close" onclick="closeModal('{host['dirname']}')">&times;</button>
            </div>
            <div class="modal-body">
                <table class="history-table">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th>Report File</th>
                            <th>Upload Time</th>
                            <th>Action</th>
                        </tr>
                    </thead>
                    <tbody>{rows}
                    </tbody>
                </table>
                <p class="history-note">Showing up to 20 most recent reports ({host['report_count']} total)</p>
            </div>
        </div>
    </div>"""


def generate_table_row(host):
    """Generate an HTML table row for a host."""
    hostname_escaped = html_escape(host["hostname"])
    os_escaped = html_escape(host["os"])
    ip_escaped = html_escape(host["ip"])
    status_badge = generate_status_badge(host["status"])

    return f"""
            <tr data-hostname="{hostname_escaped.lower()}" data-os="{os_escaped.lower()}" data-status="{host['status'].lower()}">
                <td class="cell-hostname">{hostname_escaped}</td>
                <td>{os_escaped}</td>
                <td>{ip_escaped}</td>
                <td>{host['latest_time']}</td>
                <td>{status_badge}</td>
                <td class="cell-actions">
                    <a href="{host['latest_url']}" target="_blank" class="btn-view">View Report</a>
                    <button class="btn-history" onclick="openModal('{host['dirname']}')">History ({host['report_count']})</button>
                </td>
            </tr>"""


def generate_dashboard_html(hosts, web_root):
    """Generate the complete dashboard HTML page."""

    # Calculate summary statistics
    total_hosts = len(hosts)
    pass_count = sum(1 for h in hosts if h["status"].upper() == "PASS")
    warn_count = sum(1 for h in hosts if h["status"].upper() == "WARNING")
    fail_count = sum(1 for h in hosts if h["status"].upper() == "FAIL")

    # Generate table rows
    table_rows = ""
    modals = ""
    for host in hosts:
        table_rows += generate_table_row(host)
        modals += generate_history_modal(host)

    generated_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Read custom CSS if available
    custom_css = ""
    css_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates", "style.css")
    if os.path.isfile(css_path):
        try:
            with open(css_path, "r", encoding="utf-8") as f:
                custom_css = f.read()
        except Exception as e:
            logger.warning("Could not read style.css: %s", e)

    dashboard_html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Enterprise Linux Health Dashboard</title>
    <meta name="description" content="Enterprise Linux Server Health Monitoring Dashboard">
    <style>
        /* === RESET & BASE === */
        *, *::before, *::after {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: #f0f2f5;
            color: #333;
            line-height: 1.6;
            font-size: 14px;
            min-height: 100vh;
        }}

        /* === NAVBAR === */
        .navbar {{
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            color: #fff;
            padding: 20px 30px;
            box-shadow: 0 4px 15px rgba(0,0,0,0.3);
            position: sticky;
            top: 0;
            z-index: 100;
        }}
        .navbar-inner {{
            max-width: 1400px;
            margin: 0 auto;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 15px;
        }}
        .navbar h1 {{
            font-size: 1.6em;
            font-weight: 700;
            letter-spacing: 0.5px;
        }}
        .navbar h1 .icon {{ margin-right: 10px; font-size: 1.1em; }}
        .navbar-info {{
            display: flex;
            gap: 20px;
            align-items: center;
            flex-wrap: wrap;
        }}
        .navbar-stat {{
            text-align: center;
            padding: 5px 15px;
            border-radius: 8px;
            background: rgba(255,255,255,0.1);
        }}
        .navbar-stat .stat-value {{
            font-size: 1.6em;
            font-weight: 800;
            line-height: 1;
        }}
        .navbar-stat .stat-label {{
            font-size: 0.7em;
            text-transform: uppercase;
            letter-spacing: 1px;
            opacity: 0.8;
        }}
        .navbar-stat.pass .stat-value {{ color: #56ffa4; }}
        .navbar-stat.warn .stat-value {{ color: #ffd93d; }}
        .navbar-stat.fail .stat-value {{ color: #ff6b6b; }}
        .navbar-stat.total .stat-value {{ color: #74b9ff; }}

        /* === CONTAINER === */
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            padding: 25px 30px;
        }}

        /* === TOOLBAR === */
        .toolbar {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
            flex-wrap: wrap;
            gap: 15px;
        }}
        .search-box {{
            position: relative;
            flex: 1;
            max-width: 400px;
        }}
        .search-box input {{
            width: 100%;
            padding: 12px 18px 12px 45px;
            border: 2px solid #e0e0e0;
            border-radius: 10px;
            font-size: 0.95em;
            background: #fff;
            transition: border-color 0.3s ease, box-shadow 0.3s ease;
            outline: none;
        }}
        .search-box input:focus {{
            border-color: #4a6cf7;
            box-shadow: 0 0 0 3px rgba(74, 108, 247, 0.15);
        }}
        .search-box::before {{
            content: "\\1F50D";
            position: absolute;
            left: 15px;
            top: 50%;
            transform: translateY(-50%);
            font-size: 1.1em;
        }}
        .filter-group {{
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
        }}
        .filter-btn {{
            padding: 8px 18px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            background: #fff;
            cursor: pointer;
            font-size: 0.85em;
            font-weight: 600;
            transition: all 0.2s ease;
            color: #555;
        }}
        .filter-btn:hover {{ border-color: #4a6cf7; color: #4a6cf7; }}
        .filter-btn.active {{ background: #4a6cf7; color: #fff; border-color: #4a6cf7; }}
        .filter-btn.active-pass {{ background: #28a745; color: #fff; border-color: #28a745; }}
        .filter-btn.active-warn {{ background: #e6a817; color: #fff; border-color: #e6a817; }}
        .filter-btn.active-fail {{ background: #dc3545; color: #fff; border-color: #dc3545; }}

        /* === TABLE === */
        .table-card {{
            background: #fff;
            border-radius: 12px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.08);
            overflow: hidden;
        }}
        .table-responsive {{ overflow-x: auto; }}
        .dashboard-table {{
            width: 100%;
            border-collapse: collapse;
        }}
        .dashboard-table thead th {{
            background: #f8f9fa;
            padding: 14px 18px;
            text-align: left;
            font-weight: 700;
            color: #555;
            font-size: 0.85em;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            border-bottom: 2px solid #e9ecef;
            cursor: pointer;
            user-select: none;
            white-space: nowrap;
            transition: background 0.2s ease;
        }}
        .dashboard-table thead th:hover {{ background: #e9ecef; }}
        .dashboard-table thead th .sort-icon {{ margin-left: 5px; opacity: 0.4; }}
        .dashboard-table thead th.sorted .sort-icon {{ opacity: 1; color: #4a6cf7; }}
        .dashboard-table tbody td {{
            padding: 14px 18px;
            border-bottom: 1px solid #f0f0f0;
            vertical-align: middle;
        }}
        .dashboard-table tbody tr {{
            transition: background 0.2s ease;
        }}
        .dashboard-table tbody tr:hover {{ background: #f8f9ff; }}
        .cell-hostname {{
            font-weight: 700;
            color: #2c3e50;
        }}
        .cell-actions {{
            display: flex;
            gap: 8px;
            white-space: nowrap;
        }}

        /* === STATUS BADGES === */
        .status-badge {{
            display: inline-block;
            padding: 4px 16px;
            border-radius: 20px;
            font-size: 0.78em;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }}
        .badge-pass {{ background: #d4edda; color: #155724; }}
        .badge-warn {{ background: #fff3cd; color: #856404; }}
        .badge-fail {{ background: #f8d7da; color: #721c24; }}
        .badge-unknown {{ background: #e2e3e5; color: #383d41; }}

        /* === BUTTONS === */
        .btn-view {{
            display: inline-block;
            padding: 6px 16px;
            background: linear-gradient(135deg, #4a6cf7, #6366f1);
            color: #fff;
            border-radius: 6px;
            font-size: 0.82em;
            font-weight: 600;
            text-decoration: none;
            transition: all 0.2s ease;
            border: none;
            cursor: pointer;
        }}
        .btn-view:hover {{ background: linear-gradient(135deg, #3b5de7, #5558e1); transform: translateY(-1px); box-shadow: 0 3px 8px rgba(74,108,247,0.3); text-decoration: none; }}
        .btn-history {{
            display: inline-block;
            padding: 6px 16px;
            background: #fff;
            color: #4a6cf7;
            border: 2px solid #4a6cf7;
            border-radius: 6px;
            font-size: 0.82em;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
        }}
        .btn-history:hover {{ background: #4a6cf7; color: #fff; transform: translateY(-1px); }}
        .btn-view-sm {{
            padding: 4px 12px;
            background: #4a6cf7;
            color: #fff;
            border-radius: 4px;
            font-size: 0.8em;
            text-decoration: none;
        }}
        .btn-view-sm:hover {{ background: #3b5de7; text-decoration: none; }}

        /* === MODAL === */
        .modal-overlay {{
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0,0,0,0.5);
            z-index: 1000;
            justify-content: center;
            align-items: center;
            backdrop-filter: blur(4px);
        }}
        .modal-overlay.active {{ display: flex; }}
        .modal-content {{
            background: #fff;
            border-radius: 12px;
            width: 90%;
            max-width: 800px;
            max-height: 80vh;
            overflow: hidden;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            animation: modalSlideIn 0.3s ease;
        }}
        @keyframes modalSlideIn {{
            from {{ opacity: 0; transform: translateY(-20px); }}
            to {{ opacity: 1; transform: translateY(0); }}
        }}
        .modal-header {{
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #fff;
            padding: 18px 25px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}
        .modal-header h3 {{ font-size: 1.1em; }}
        .modal-close {{
            background: none;
            border: none;
            color: #fff;
            font-size: 1.5em;
            cursor: pointer;
            opacity: 0.8;
            transition: opacity 0.2s;
            line-height: 1;
        }}
        .modal-close:hover {{ opacity: 1; }}
        .modal-body {{
            padding: 20px 25px;
            overflow-y: auto;
            max-height: calc(80vh - 70px);
        }}
        .history-table {{
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9em;
        }}
        .history-table th {{
            background: #f8f9fa;
            padding: 10px 12px;
            text-align: left;
            font-weight: 700;
            border-bottom: 2px solid #dee2e6;
        }}
        .history-table td {{
            padding: 10px 12px;
            border-bottom: 1px solid #eee;
        }}
        .history-note {{
            margin-top: 15px;
            color: #888;
            font-size: 0.85em;
            font-style: italic;
        }}

        /* === EMPTY STATE === */
        .empty-state {{
            text-align: center;
            padding: 60px 20px;
            color: #888;
        }}
        .empty-state .icon {{ font-size: 3em; margin-bottom: 15px; }}
        .empty-state h3 {{ color: #555; margin-bottom: 10px; }}

        /* === FOOTER === */
        .page-footer {{
            text-align: center;
            padding: 25px;
            color: #888;
            font-size: 0.85em;
            margin-top: 20px;
        }}
        .page-footer strong {{ color: #4a6cf7; }}

        /* === NO RESULTS === */
        .no-results {{
            display: none;
            text-align: center;
            padding: 40px;
            color: #888;
            font-size: 1.1em;
        }}

        /* === RESPONSIVE === */
        @media (max-width: 768px) {{
            .navbar {{ padding: 15px; }}
            .navbar h1 {{ font-size: 1.2em; }}
            .navbar-info {{ gap: 8px; }}
            .container {{ padding: 15px; }}
            .toolbar {{ flex-direction: column; }}
            .search-box {{ max-width: 100%; }}
            .cell-actions {{ flex-direction: column; gap: 4px; }}
        }}

        {custom_css}
    </style>
</head>
<body>

    <!-- Navigation Bar -->
    <nav class="navbar">
        <div class="navbar-inner">
            <div>
                <h1><span class="icon">&#x1F5A5;</span> Enterprise Linux Health Dashboard</h1>
            </div>
            <div class="navbar-info">
                <div class="navbar-stat total">
                    <div class="stat-value">{total_hosts}</div>
                    <div class="stat-label">Servers</div>
                </div>
                <div class="navbar-stat pass">
                    <div class="stat-value">{pass_count}</div>
                    <div class="stat-label">Passed</div>
                </div>
                <div class="navbar-stat warn">
                    <div class="stat-value">{warn_count}</div>
                    <div class="stat-label">Warnings</div>
                </div>
                <div class="navbar-stat fail">
                    <div class="stat-value">{fail_count}</div>
                    <div class="stat-label">Failed</div>
                </div>
            </div>
        </div>
    </nav>

    <div class="container">

        <!-- Toolbar: Search + Filter -->
        <div class="toolbar">
            <div class="search-box">
                <input type="text" id="searchInput" placeholder="Search by hostname, OS, IP..." onkeyup="filterTable()">
            </div>
            <div class="filter-group">
                <button class="filter-btn active" onclick="filterByStatus('all', this)">All ({total_hosts})</button>
                <button class="filter-btn" onclick="filterByStatus('pass', this)">Pass ({pass_count})</button>
                <button class="filter-btn" onclick="filterByStatus('warning', this)">Warning ({warn_count})</button>
                <button class="filter-btn" onclick="filterByStatus('fail', this)">Fail ({fail_count})</button>
            </div>
        </div>

        <!-- Server Table -->
        <div class="table-card">
            <div class="table-responsive">
                <table class="dashboard-table" id="serverTable">
                    <thead>
                        <tr>
                            <th onclick="sortTable(0)">Server Name <span class="sort-icon">&#x2195;</span></th>
                            <th onclick="sortTable(1)">Operating System <span class="sort-icon">&#x2195;</span></th>
                            <th onclick="sortTable(2)">IP Address <span class="sort-icon">&#x2195;</span></th>
                            <th onclick="sortTable(3)">Last Report Time <span class="sort-icon">&#x2195;</span></th>
                            <th onclick="sortTable(4)">Status <span class="sort-icon">&#x2195;</span></th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody id="serverTableBody">
                        {table_rows if table_rows else '<tr><td colspan="6"><div class="empty-state"><div class="icon">&#x1F4E5;</div><h3>No Reports Yet</h3><p>Health check reports will appear here after servers upload their first report.</p></div></td></tr>'}
                    </tbody>
                </table>
            </div>
            <div class="no-results" id="noResults">
                &#x1F50D; No servers match your search criteria
            </div>
        </div>

    </div>

    <!-- History Modals -->
    {modals}

    <!-- Footer -->
    <footer class="page-footer">
        <strong>Enterprise Linux Health Dashboard</strong> &mdash; Last updated: {generated_time}
        <br>
        Monitoring {total_hosts} server{"s" if total_hosts != 1 else ""} &bull; {pass_count} healthy &bull; {warn_count} warnings &bull; {fail_count} critical
    </footer>

    <script>
    /* ===== Search / Filter ===== */
    var currentFilter = 'all';

    function filterTable() {{
        var input = document.getElementById('searchInput').value.toLowerCase();
        var rows = document.querySelectorAll('#serverTableBody tr[data-hostname]');
        var visibleCount = 0;

        for (var i = 0; i < rows.length; i++) {{
            var hostname = rows[i].getAttribute('data-hostname') || '';
            var os = rows[i].getAttribute('data-os') || '';
            var status = rows[i].getAttribute('data-status') || '';
            var ip = rows[i].cells[2] ? rows[i].cells[2].textContent.toLowerCase() : '';

            var matchesSearch = hostname.indexOf(input) > -1 ||
                               os.indexOf(input) > -1 ||
                               ip.indexOf(input) > -1;
            var matchesFilter = currentFilter === 'all' || status === currentFilter;

            if (matchesSearch && matchesFilter) {{
                rows[i].style.display = '';
                visibleCount++;
            }} else {{
                rows[i].style.display = 'none';
            }}
        }}

        document.getElementById('noResults').style.display = visibleCount === 0 ? 'block' : 'none';
    }}

    function filterByStatus(status, btn) {{
        currentFilter = status;

        var buttons = document.querySelectorAll('.filter-btn');
        for (var i = 0; i < buttons.length; i++) {{
            buttons[i].className = 'filter-btn';
        }}

        btn.classList.add('active');
        if (status === 'pass') btn.classList.add('active-pass');
        else if (status === 'warning') btn.classList.add('active-warn');
        else if (status === 'fail') btn.classList.add('active-fail');

        filterTable();
    }}

    /* ===== Table Sort ===== */
    var sortDirections = {{}};

    function sortTable(columnIndex) {{
        var table = document.getElementById('serverTable');
        var tbody = table.tBodies[0];
        var rows = Array.from(tbody.querySelectorAll('tr[data-hostname]'));

        if (!sortDirections[columnIndex]) sortDirections[columnIndex] = 'asc';
        else sortDirections[columnIndex] = sortDirections[columnIndex] === 'asc' ? 'desc' : 'asc';

        var dir = sortDirections[columnIndex];

        rows.sort(function(a, b) {{
            var aText = a.cells[columnIndex] ? a.cells[columnIndex].textContent.trim().toLowerCase() : '';
            var bText = b.cells[columnIndex] ? b.cells[columnIndex].textContent.trim().toLowerCase() : '';
            if (aText < bText) return dir === 'asc' ? -1 : 1;
            if (aText > bText) return dir === 'asc' ? 1 : -1;
            return 0;
        }});

        for (var i = 0; i < rows.length; i++) {{
            tbody.appendChild(rows[i]);
        }}

        // Update sort indicators
        var ths = table.querySelectorAll('thead th');
        for (var j = 0; j < ths.length; j++) {{
            ths[j].classList.remove('sorted');
        }}
        if (ths[columnIndex]) ths[columnIndex].classList.add('sorted');
    }}

    /* ===== Modal ===== */
    function openModal(hostId) {{
        var modal = document.getElementById('modal-' + hostId);
        if (modal) modal.classList.add('active');
    }}

    function closeModal(hostId) {{
        var modal = document.getElementById('modal-' + hostId);
        if (modal) modal.classList.remove('active');
    }}

    // Close modal on Escape key
    document.addEventListener('keydown', function(e) {{
        if (e.key === 'Escape') {{
            var modals = document.querySelectorAll('.modal-overlay.active');
            for (var i = 0; i < modals.length; i++) {{
                modals[i].classList.remove('active');
            }}
        }}
    }});
    </script>

</body>
</html>"""

    return dashboard_html


# =============================================================================
# MAIN
# =============================================================================


def main():
    """Main entry point for dashboard generation."""
    # Determine web root from command line or default
    if len(sys.argv) > 1:
        web_root = sys.argv[1]
    else:
        web_root = DEFAULT_WEB_ROOT

    logger.info("=" * 60)
    logger.info("Enterprise Linux Health Dashboard - Generator")
    logger.info("=" * 60)
    logger.info("Web root: %s", web_root)

    # Scan for reports
    hosts = scan_reports(web_root)
    logger.info("Found %d hosts with reports", len(hosts))

    # Generate dashboard HTML
    dashboard_html = generate_dashboard_html(hosts, web_root)

    # Write to index.html
    output_path = os.path.join(web_root, "index.html")
    try:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(dashboard_html)
        logger.info("Dashboard written to: %s", output_path)
        logger.info("Dashboard generated successfully with %d servers", len(hosts))
    except Exception as e:
        logger.error("Failed to write dashboard: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
