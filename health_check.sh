#!/bin/bash
# =============================================================================
# Enterprise Linux Health Check - Standalone Client Script
# =============================================================================
# Single self-contained script for production Linux client servers.
# Collects system metrics and generates TXT and HTML reports.
#
# Supported OS: RHEL 6, 7, 8, 9, 10 | Ubuntu 18, 20, 22, 24 | amazon linux
#
# Usage:
#   chmod +x health_check.sh
#   ./health_check.sh
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
REPORT_SERVER="10.0.27.53"
REPORT_PORT="5000"
UPLOAD_URL="http://${REPORT_SERVER}:${REPORT_PORT}/upload"

REPORT_DIR="/opt/health-reports"
LOG_FILE="/var/log/health_check.log"
REPORT_PREFIX="HealthCheck"
TIMESTAMP_FORMAT="%F_%H-%M-%S"

# Upload Retries
UPLOAD_RETRIES=3
UPLOAD_TIMEOUT=30
UPLOAD_RETRY_DELAY=5

# Key Services to check
CHECK_SERVICES="ntpd chronyd snmpd sendmail postfix vsftpd"

# =============================================================================
# GLOBAL STATE & OS DETECTION
# =============================================================================
OS_FAMILY="Unknown"
OS_VERSION="Unknown"
OS_FULL="Unknown"
USE_SYSTEMCTL=false
USE_IP=true
USE_SS=true
USE_CHKCONFIG=false
USE_FIREWALLD=false
USE_UFW=false

detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS_FULL=$(cat /etc/redhat-release)
        OS_FAMILY="RHEL"
        OS_VERSION=$(grep -o '[0-9]*' /etc/redhat-release | head -1)

        case "$OS_VERSION" in
            6)
                USE_SYSTEMCTL=false
                USE_IP=false
                USE_SS=false
                USE_CHKCONFIG=true
                ;;
            7)
                USE_SYSTEMCTL=true
                USE_CHKCONFIG=true
                USE_FIREWALLD=true
                ;;
            8|9|10)
                USE_SYSTEMCTL=true
                USE_CHKCONFIG=false
                USE_FIREWALLD=true
                ;;
        esac
    elif [ -f /etc/os-release ]; then
    . /etc/os-release

        case "$ID" in
		amzn)
			OS_FAMILY="Amazon Linux"
               		OS_VERSION=$(echo "$VERSION_ID" | cut -d. -f1)
            		OS_FULL="${PRETTY_NAME}"

            		USE_SYSTEMCTL=true
           	 	USE_FIREWALLD=true
            		USE_IP=true
            		USE_SS=true
            		USE_CHKCONFIG=false
            		;;

        	ubuntu|debian)
            		OS_FAMILY="Ubuntu"
            		OS_VERSION=$(echo "$VERSION_ID" | cut -d. -f1)
            		OS_FULL="${PRETTY_NAME}"

            		USE_SYSTEMCTL=true
            		USE_UFW=true
            		USE_IP=true
            		USE_SS=true
            		;;

        *)
            OS_FAMILY="$NAME"
            OS_VERSION="$VERSION_ID"
            OS_FULL="${PRETTY_NAME:-$NAME}"

            USE_SYSTEMCTL=true
            USE_IP=true
            USE_SS=true
            ;;
    esac
fi


    command -v systemctl >/dev/null 2>&1 && USE_SYSTEMCTL=true
    command -v ip >/dev/null 2>&1 && USE_IP=true
    command -v ss >/dev/null 2>&1 && USE_SS=true
    command -v chkconfig >/dev/null 2>&1 && USE_CHKCONFIG=true
    command -v firewall-cmd >/dev/null 2>&1 && USE_FIREWALLD=true
    command -v ufw >/dev/null 2>&1 && USE_UFW=true

    if ! command -v systemctl >/dev/null 2>&1; then USE_SYSTEMCTL=false; fi
    if ! command -v ip >/dev/null 2>&1; then USE_IP=false; fi
    if ! command -v ss >/dev/null 2>&1; then USE_SS=false; fi
}

check_service_status() {
    local svc="$1"
    local output=""
    local status="UNKNOWN"

    if [ "$USE_SYSTEMCTL" = true ]; then
        output=$(systemctl status "$svc" --no-pager 2>&1)
        if echo "$output" | grep -q "Active: active (running)"; then
            status="RUNNING"
        elif echo "$output" | grep -q "Active: active"; then
            status="ACTIVE"
        elif echo "$output" | grep -q "could not be found\|not-found\|Unit .* not found"; then
            status="NOT_INSTALLED"
        else
            status="STOPPED"
        fi
    else
        output=$(service "$svc" status 2>&1)
        if echo "$output" | grep -qi "running\|is active"; then
            status="RUNNING"
        elif echo "$output" | grep -qi "unrecognized\|not found\|No such"; then
            status="NOT_INSTALLED"
        else
            status="STOPPED"
        fi
    fi

    echo "${status}|${output}"
}

get_ip_addresses() {
    if [ "$USE_IP" = true ]; then
        ip addr 2>/dev/null
    else
        ifconfig -a 2>/dev/null
    fi
}

get_routes() {
    if [ "$USE_IP" = true ]; then
        ip route 2>/dev/null
    else
        route -n 2>/dev/null
    fi
}

get_listening_ports() {
    if [ "$USE_SS" = true ]; then
        ss -tulnp 2>/dev/null
    else
        netstat -tulnp 2>/dev/null | grep LISTEN
    fi
}

# =============================================================================
# REPORT GENERATORS (TXT & HTML)
# =============================================================================
txt_header() {
    local title="$1"
    {
        echo ""
        echo "==================================================================="
        echo "$title"
        echo "==================================================================="
    } >> "$TXT_REPORT"
}

txt_cmd() {
    local label="$1"
    local output="$2"
    {
        echo ""
        echo "-------------------- $label --------------------"
        if [ -n "$output" ] && [ "$output" != "Not Available" ]; then
            echo "$output"
        else
            echo "Not Applicable / Command Failed"
        fi
    } >> "$TXT_REPORT"
}

txt_line() {
    echo "$1" >> "$TXT_REPORT"
}

html_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g'
}

html_report_start() {
    local hostname_val="$1"
    local ip_addr="$2"
    local os_info="$3"
    local report_date="$4"
    local kernel="$5"

    cat >> "$HTML_REPORT" << 'HTMLHEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
HTMLHEADER

    cat >> "$HTML_REPORT" << HTMLMETA
    <meta name="report-hostname" content="${hostname_val}">
    <meta name="report-os" content="${OS_FULL}">
    <meta name="report-kernel" content="${kernel}">
    <meta name="report-ip" content="${ip_addr}">
    <meta name="report-date" content="${report_date}">
    <meta name="report-status" content="COMPLETED">
    <title>Health Check - ${hostname_val} - ${report_date}</title>
    <script src="https://unpkg.com/lucide@latest"></script>
HTMLMETA

    cat >> "$HTML_REPORT" << 'HTMLSTYLE'
    <style>
        *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;
            background: #f0f2f5;
            color: #333;
            line-height: 1.6;
            font-size: 14px;
        }
        a { color: #4a6cf7; text-decoration: none; }
        a:hover { text-decoration: underline; }

        html { scroll-behavior: smooth; }

        .top-nav {
            background: linear-gradient(90deg, #C61D24 0%, #B41E2C 25%, #8D2757 50%, #4F6CEB 75%, #1754D1 100%);
            color: #ffffff;
            height: 85px;
            min-height: 85px;
            padding: 0 30px;
            position: sticky;
            top: 0;
            z-index: 1000;
            box-shadow: 0 8px 24px rgba(23, 84, 209, 0.15);
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
            border-bottom: 1px solid rgba(255, 255, 255, 0.15);
            border-bottom-left-radius: 14px;
            border-bottom-right-radius: 14px;
            display: flex;
            align-items: center;
        }
        .top-nav .nav-content {
            max-width: 1600px;
            margin: 0 auto;
            width: 100%;
            display: grid;
            grid-template-columns: 200px 1fr 200px;
            align-items: center;
        }
        .nav-left { display: flex; align-items: center; }
        .btn-back-dashboard {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            background: #ffffff;
            color: #202939 !important;
            border: 1px solid #E6EAF2;
            padding: 8px 18px;
            border-radius: 12px;
            font-size: 0.88em;
            font-weight: 600;
            text-decoration: none !important;
            transition: all 0.25s ease;
            box-shadow: 0 2px 6px rgba(0,0,0,0.1);
        }
        .btn-back-dashboard:hover {
            background: #C61D24;
            color: #ffffff !important;
            border-color: #C61D24;
            box-shadow: 0 4px 12px rgba(198, 29, 36, 0.3);
        }
        .nav-center { text-align: center; }
        .report-title-wrap {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
        }
        .report-title-icon { font-size: 1.3em; }
        .report-title-text {
            font-size: 24px;
            font-weight: 600;
            color: #ffffff;
            line-height: 1.2;
            letter-spacing: -0.4px;
        }
        .nav-meta-row {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 14px;
            font-size: 13.5px;
            color: rgba(255, 255, 255, 0.88);
            white-space: nowrap;
            margin-top: 3px;
            font-weight: 500;
        }
        .nav-meta-item strong { color: #ffffff; font-weight: 600; }
        .meta-dot { color: rgba(255, 255, 255, 0.4); font-size: 0.9em; }
        .nav-right { width: 100%; }

        .page-layout { display: flex; min-height: calc(100vh - 85px); }

        .sidebar {
            position: sticky;
            top: 89px;
            width: 240px;
            min-width: 240px;
            height: calc(100vh - 89px);
            background: #ffffff;
            box-shadow: 2px 0 10px rgba(32, 41, 57, 0.04);
            overflow-y: auto;
            padding: 15px 0;
            border-right: 1px solid #E6EAF2;
        }
        .side-nav-title {
            font-size: 0.74em;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1.5px;
            background: linear-gradient(90deg, #C61D24, #FF6464);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            padding: 16px 20px 6px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .side-title-icon {
            font-size: 1.1em;
            -webkit-text-fill-color: #C61D24;
        }
        .side-nav a {
            display: block;
            padding: 9px 16px 9px 20px;
            margin: 2px 10px;
            border-radius: 8px;
            color: #4B5563;
            font-size: 0.86em;
            font-weight: 500;
            border-left: 3px solid transparent;
            transition: all 0.2s ease;
        }
        .side-nav a:hover {
            background: #F8FAFC;
            color: #C61D24;
        }
        .side-nav a.active {
            color: #C61D24;
            background: #FDF2F2;
            border-left: 3.5px solid #C61D24;
            border-top-left-radius: 4px;
            border-bottom-left-radius: 4px;
            font-weight: 600;
        }

        .side-nav [data-lucide] {
            width: 14px !important;
            height: 14px !important;
        }
        .side-nav-title [data-lucide] {
            width: 14px !important;
            height: 14px !important;
        }
        .nav-item-icon {
            display: inline-block;
            margin-right: 8px;
            width: 14px;
            height: 14px;
            vertical-align: -2px;
            opacity: 0.75;
        }

        .main-content {
            flex: 1;
            padding: 30px;
            max-width: calc(100% - 240px);
        }

        .report-section {
            scroll-margin-top: 100px;
            margin-bottom: 24px;
            background: #ffffff;
            border-radius: 16px;
            box-shadow: 0 4px 20px rgba(32, 41, 57, 0.05);
            border: 1px solid #E6EAF2;
            overflow: hidden;
            position: relative;
            transition: box-shadow 0.25s ease, transform 0.25s ease;
        }
        .report-section:hover {
            box-shadow: 0 8px 28px rgba(32, 41, 57, 0.08);
        }
        .report-section::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            bottom: 0;
            width: 4px;
            border-radius: 4px;
            background: #1754D1;
            z-index: 2;
        }

        .section-header {
            background: #ffffff;
            padding: 18px 26px 18px 28px;
            border-bottom: 1px solid #E6EAF2;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            user-select: none;
        }
        .section-header h3 {
            font-size: 1.1em;
            font-weight: 600;
            color: #202939;
            letter-spacing: -0.2px;
        }
        .header-right { display: flex; align-items: center; gap: 12px; }
        .toggle-icon { font-size: 0.9em; color: #6B7280; transition: transform 0.3s; }
        .toggle-icon.collapsed { transform: rotate(-90deg); }
        .section-body {
            background: #ffffff;
            padding: 22px 28px;
        }
        .section-body.hidden { display: none; }

        .badge { display: inline-block; padding: 4px 14px; border-radius: 20px; font-size: 0.75em; font-weight: 600; text-transform: uppercase; }
        .badge-info { background: #DBEAFE; color: #1754D1; }
        .badge-success { background: #DCFCE7; color: #16A34A; }

        .table-responsive { overflow-x: auto; margin-bottom: 15px; border-radius: 12px; border: 1px solid #E6EAF2; }
        .table { width: 100%; border-collapse: collapse; font-size: 0.9em; }
        .table th { background: #F6F8FC; padding: 12px 16px; text-align: left; font-weight: 600; color: #6B7280; border-bottom: 2px solid #E6EAF2; font-size: 0.82em; text-transform: uppercase; }
        .table td { padding: 12px 16px; border-bottom: 1px solid #E6EAF2; font-weight: 500; }
        .table tr:hover { background: #F8FAFC; }
        .info-table th { width: 200px; background: #EFF6FF; color: #1754D1; }

        .progress-group { margin-bottom: 14px; }
        .progress-label { display: flex; justify-content: space-between; margin-bottom: 5px; font-size: 0.88em; font-weight: 500; }
        .progress-container { height: 22px; background: #E6EAF2; border-radius: 11px; overflow: hidden; }
        .progress-bar { height: 100%; border-radius: 11px; display: flex; align-items: center; justify-content: center; font-size: 0.75em; font-weight: 600; color: #fff; background: linear-gradient(90deg, #1754D1, #4F8BFF); }

        .cmd-block { margin-bottom: 15px; }
        .cmd-label { font-size: 0.82em; font-weight: 600; color: #fff; background: #202939; padding: 6px 14px; border-radius: 6px 6px 0 0; display: inline-block; }
        pre { background: #0F172A; color: #E2E8F0; padding: 16px 20px; border-radius: 0 8px 8px 8px; overflow-x: auto; font-size: 0.84em; font-family: 'SFMono-Regular', Consolas, monospace; margin: 0; white-space: pre-wrap; }

        .page-footer { text-align: center; padding: 25px; color: #6B7280; font-size: 0.85em; font-weight: 500; background: #ffffff; border-top: 1px solid #E6EAF2; margin-top: 30px; }

        @media (max-width: 992px) {
            .top-nav .nav-content { grid-template-columns: 1fr; gap: 8px; text-align: center; }
            .nav-left { justify-content: center; }
            .nav-meta-row { flex-wrap: wrap; }
            .sidebar { display: none; }
            .main-content { max-width: 100%; padding: 20px 15px; }
        }
    </style>
</head>
<body>
HTMLSTYLE

    cat >> "$HTML_REPORT" << HTMLNAV
    <nav class="top-nav">
        <div class="nav-content">
            <div class="nav-left">
                <a href="/" class="btn-back-dashboard"><i data-lucide="arrow-left" style="width:16px;height:16px;vertical-align:middle;"></i> Back to Dashboard</a>
            </div>
            <div class="nav-center">
                <div class="report-title-wrap">
                    <i data-lucide="file-text" style="width:24px;height:24px;color:#ffffff;"></i>
                    <h1 class="report-title-text">Linux Health Check Report</h1>
                </div>
                <div class="nav-meta-row">
                    <span class="nav-meta-item"><strong>Host:</strong> ${hostname_val}</span>
                    <span class="meta-dot">&bull;</span>
                    <span class="nav-meta-item"><strong>OS:</strong> ${os_info}</span>
                    <span class="meta-dot">&bull;</span>
                    <span class="nav-meta-item"><strong>IP:</strong> ${ip_addr}</span>
                    <span class="meta-dot">&bull;</span>
                    <span class="nav-meta-item"><strong>Generated:</strong> ${report_date}</span>
                </div>
            </div>
            <div class="nav-right"></div>
        </div>
    </nav>
    <div class="page-layout">
    <aside class="sidebar">
        <nav class="side-nav">
            <div class="side-nav-title"><i data-lucide="settings-2" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> SYSTEM</div>
            <a href="#system-info"><i data-lucide="monitor-smartphone" class="nav-item-icon"></i> System Info</a>
            <a href="#hardware"><i data-lucide="cpu" class="nav-item-icon"></i> Hardware</a>
            <a href="#kernel"><i data-lucide="code-xml" class="nav-item-icon"></i> Kernel</a>
            <div class="side-nav-title"><i data-lucide="database" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> STORAGE</div>
            <a href="#disk"><i data-lucide="hard-drive" class="nav-item-icon"></i> Disk Usage</a>
            <a href="#lvm"><i data-lucide="layers-3" class="nav-item-icon"></i> LVM</a>
            <a href="#filesystem"><i data-lucide="folder" class="nav-item-icon"></i> Filesystem</a>
            <a href="#multipath"><i data-lucide="git-branch-plus" class="nav-item-icon"></i> Multipath</a>
            <div class="side-nav-title"><i data-lucide="memory-stick" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> MEMORY</div>
            <a href="#memory"><i data-lucide="memory-stick" class="nav-item-icon"></i> Memory</a>
            <a href="#performance"><i data-lucide="activity" class="nav-item-icon"></i> Performance</a>
            <div class="side-nav-title"><i data-lucide="globe" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> NETWORK</div>
            <a href="#network"><i data-lucide="globe" class="nav-item-icon"></i> Network</a>
            <a href="#network-config"><i data-lucide="settings-2" class="nav-item-icon"></i> Network Config</a>
            <a href="#bonding"><i data-lucide="link-2" class="nav-item-icon"></i> Bond Status</a>
            <a href="#routing"><i data-lucide="route" class="nav-item-icon"></i> Routing</a>
            <a href="#dns"><i data-lucide="badge-info" class="nav-item-icon"></i> DNS</a>
            <a href="#ports"><i data-lucide="plug-zap" class="nav-item-icon"></i> Listening Ports</a>
            <div class="side-nav-title"><i data-lucide="shield" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> SECURITY</div>
            <a href="#firewall"><i data-lucide="shield-check" class="nav-item-icon"></i> Firewall</a>
            <a href="#selinux"><i data-lucide="shield-ellipsis" class="nav-item-icon"></i> SELinux</a>
            <div class="side-nav-title"><i data-lucide="server" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> SERVICES</div>
            <a href="#ntp"><i data-lucide="clock-3" class="nav-item-icon"></i> NTP</a>
            <a href="#services"><i data-lucide="server" class="nav-item-icon"></i> Services</a>
            <a href="#exports"><i data-lucide="folder-sync" class="nav-item-icon"></i> NFS Exports</a>
            <div class="side-nav-title"><i data-lucide="settings" style="width:16px;height:16px;-webkit-text-fill-color:#C61D24;"></i> CONFIG & USERS</div>
            <a href="#cron"><i data-lucide="calendar-clock" class="nav-item-icon"></i> Cron</a>
            <a href="#sysctl"><i data-lucide="sliders-horizontal" class="nav-item-icon"></i> Sysctl</a>
            <a href="#limits"><i data-lucide="gauge" class="nav-item-icon"></i> Limits</a>
            <a href="#users"><i data-lucide="house" class="nav-item-icon"></i> Home Directory</a>
        </nav>
    </aside>
    <main class="main-content">
HTMLNAV
}

html_report_end() {
    local report_date
    report_date=$(date '+%Y-%m-%d %H:%M:%S')

    cat >> "$HTML_REPORT" << HTMLFOOTER
    </main>
    </div>
    <footer class="page-footer">Generated by <strong>Enterprise Linux Health Dashboard</strong> on ${report_date}</footer>
    <script>
    (function() {
        window.toggleSection = function(sectionId) {
            var body = document.getElementById(sectionId + '-body');
            var icon = document.querySelector('[data-section="' + sectionId + '"]');
            if (body.classList.contains('hidden')) {
                body.classList.remove('hidden');
                if (icon) icon.classList.remove('collapsed');
            } else {
                body.classList.add('hidden');
                if (icon) icon.classList.add('collapsed');
            }
        };

        // Smooth scroll positioning for sidebar links stopping 90px below fixed header
        document.addEventListener('DOMContentLoaded', function() {
            if (window.lucide) { lucide.createIcons(); }
            var links = document.querySelectorAll('.side-nav a[href^="#"]');
            links.forEach(function(anchor) {
                anchor.addEventListener('click', function(e) {
                    var href = this.getAttribute('href');
                    if (href && href.length > 1) {
                        var targetId = href.substring(1);
                        var targetEl = document.getElementById(targetId);
                        if (targetEl) {
                            e.preventDefault();
                            var headerOffset = 90;
                            var elementPosition = targetEl.getBoundingClientRect().top;
                            var offsetPosition = elementPosition + window.pageYOffset - headerOffset;
                            window.scrollTo({
                                top: offsetPosition,
                                behavior: 'smooth'
                            });
                        }
                    }
                });
            });
        });
    })();
    </script>
</body>
</html>
HTMLFOOTER
}

html_section_open() {
    local section_id="$1"
    local section_title="$2"

    cat >> "$HTML_REPORT" << HTMLSEC
    <section id="${section_id}" class="report-section">
        <div class="section-header" onclick="toggleSection('${section_id}')">
            <h3>${section_title}</h3>
            <div class="header-right">
                <span class="toggle-icon" data-section="${section_id}">&#9660;</span>
            </div>
        </div>
        <div class="section-body" id="${section_id}-body">
HTMLSEC
}

html_section_close() {
    echo '</div></section>' >> "$HTML_REPORT"
}

html_info_table() {
    echo '<div class="table-responsive"><table class="table info-table">' >> "$HTML_REPORT"
    while [ $# -ge 2 ]; do
        local key="$1"
        local val
        val=$(html_escape "$2")
        echo "<tr><th>${key}</th><td>${val}</td></tr>" >> "$HTML_REPORT"
        shift 2
    done
    echo '</table></div>' >> "$HTML_REPORT"
}

html_cmd_output() {
    local label="$1"
    local output="$2"
    local escaped_output
    escaped_output=$(html_escape "$output")
    cat >> "$HTML_REPORT" << HTMLCMD
        <div class="cmd-block">
            <span class="cmd-label">$ ${label}</span>
            <pre>${escaped_output}</pre>
        </div>
HTMLCMD
}

html_progress() {
    local label="$1"
    local value="$2"

    cat >> "$HTML_REPORT" << HTMLPROG
        <div class="progress-group">
            <div class="progress-label"><span>${label}</span><span>${value}%</span></div>
            <div class="progress-container">
                <div class="progress-bar" style="width: ${value}%">${value}%</div>
            </div>
        </div>
HTMLPROG
}

html_raw() {
    echo "$1" >> "$HTML_REPORT"
}

# =============================================================================
# MAIN EXECUTION ENGINE
# =============================================================================
mkdir -p "${REPORT_DIR}" 2>/dev/null
detect_os

CURRENT_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
CURRENT_FQDN=$(hostname -f 2>/dev/null || echo "$CURRENT_HOSTNAME")
CURRENT_DATE=$(date "+${TIMESTAMP_FORMAT}")
CURRENT_DATE_DISPLAY=$(date "+%Y-%m-%d %H:%M:%S")
CURRENT_KERNEL=$(uname -r 2>/dev/null || echo "N/A")
CURRENT_UPTIME=$(uptime 2>/dev/null || echo "N/A")
CURRENT_NPROC=$(nproc 2>/dev/null || echo "1")

TXT_REPORT="${REPORT_DIR}/${REPORT_PREFIX}_${CURRENT_HOSTNAME}_${CURRENT_DATE}.txt"
HTML_REPORT="${REPORT_DIR}/${REPORT_PREFIX}_${CURRENT_HOSTNAME}_${CURRENT_DATE}.html"
JSON_REPORT="${REPORT_DIR}/${REPORT_PREFIX}_${CURRENT_HOSTNAME}_${CURRENT_DATE}.json"

echo "============================================================"
echo " Enterprise Linux Health Check"
echo "============================================================"
echo " Hostname : ${CURRENT_HOSTNAME}"
echo " IP       : ${CURRENT_IP}"
echo " OS       : ${OS_FULL}"
echo " Date     : ${CURRENT_DATE_DISPLAY}"
echo "============================================================"

> "$TXT_REPORT"
> "$HTML_REPORT"

txt_line "============================================================"
txt_line " Enterprise Linux Health Check Report"
txt_line " Hostname : ${CURRENT_HOSTNAME}"
txt_line " IP       : ${CURRENT_IP}"
txt_line " OS       : ${OS_FULL}"
txt_line " Date     : ${CURRENT_DATE_DISPLAY}"
txt_line "============================================================"

html_report_start "$CURRENT_HOSTNAME" "$CURRENT_IP" "$OS_FULL" "$CURRENT_DATE_DISPLAY" "$CURRENT_KERNEL"

# 1. SYSTEM INFORMATION
date_out=$(date 2>/dev/null)
hostname_out=$(hostname 2>/dev/null)
hostname_ip_out=$(hostname -I | awk '{print $1}' 2>/dev/null)
hostname_fqdn_out=$(hostname -f 2>/dev/null)
uptime_out=$(uptime 2>/dev/null)
uname_out=$(uname -r 2>/dev/null)
nproc_out=$(nproc 2>/dev/null)
ram_out=$(awk '/MemTotal/ {printf "%.1f GB",$2/1024/1024}' /proc/meminfo)
# NIC Count
if command -v ip >/dev/null 2>&1; then
    nic_count_out=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{count++} END{print count+0}')
else
    nic_count_out=$(ifconfig -a 2>/dev/null | grep '^[a-zA-Z]' | grep -v '^lo' | wc -l)
fi

os_release_out=""
[ -f /etc/redhat-release ] && os_release_out=$(cat /etc/redhat-release)
os_details_out=""
[ -f /etc/os-release ] && os_details_out=$(cat /etc/os-release)

txt_header "SYSTEM INFORMATION"
txt_cmd "Date" "$date_out"
txt_cmd "Hostname" "$hostname_out"
txt_cmd "Hostname IP" "$hostname_ip_out"
txt_cmd "Hostname FQDN" "$hostname_fqdn_out"
txt_cmd "Uptime" "$uptime_out"
txt_cmd "Kernel" "$uname_out"
txt_cmd "CPU Cores" "$nproc_out"
txt_cmd "Memory" "$ram_out"
txt_cmd "NIC Count" "$nic_count_out"
[ -n "$os_release_out" ] && txt_cmd "OS Release" "$os_release_out"
[ -n "$os_details_out" ] && txt_cmd "OS Details" "$os_details_out"

html_section_open "system-info" "System Information"
html_info_table "Hostname" "$hostname_out" "FQDN" "$hostname_fqdn_out" "IP Address" "$hostname_ip_out" "OS" "$OS_FULL" "Kernel" "$uname_out" "CPU Cores" "$nproc_out" "Memory" "$ram_out" "NIC Count" "$nic_count_out" "Uptime" "$uptime_out"
[ -n "$os_details_out" ] && html_cmd_output "cat /etc/os-release" "$os_details_out"
html_section_close

# 2. HARDWARE
dmidecode_out=""
command -v dmidecode >/dev/null 2>&1 && dmidecode_out=$(dmidecode -t system 2>/dev/null)
txt_header "HARDWARE"
txt_cmd "dmidecode -t system" "${dmidecode_out:-Not Available}"
html_section_open "hardware" "Hardware"
[ -n "$dmidecode_out" ] && html_cmd_output "dmidecode -t system" "$dmidecode_out" || html_raw '<p class="badge badge-info">dmidecode not available</p>'
html_section_close

# 3. KERNEL
kernel_out=$(uname -a 2>/dev/null)
txt_header "KERNEL"
txt_cmd "uname -a" "$kernel_out"
html_section_open "kernel" "Kernel"
html_info_table "Kernel Version" "$uname_out" "Full Info" "$kernel_out"
html_section_close

# 4. DISK USAGE
df_h_out=$(df -h 2>/dev/null)
df_i_out=$(df -i 2>/dev/null)
lsblk_out=$(lsblk 2>/dev/null)
fdisk_out=""
command -v fdisk >/dev/null 2>&1 && fdisk_out=$(fdisk -l 2>/dev/null)
mount_out=$(mount 2>/dev/null)

txt_header "DISK USAGE"
txt_cmd "df -h" "$df_h_out"
txt_cmd "df -i" "$df_i_out"
txt_cmd "lsblk" "$lsblk_out"
[ -n "$fdisk_out" ] && txt_cmd "fdisk -l" "$fdisk_out"
txt_cmd "mount" "$mount_out"

html_section_open "disk" "Disk Usage"
html_raw '<h4 style="margin-bottom:15px;">Filesystem Usage</h4>'
while IFS= read -r line; do
    fs=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount_point=$(echo "$line" | awk '{print $6}')
    if [ -z "$pct" ] || ! [[ "$pct" =~ ^[0-9]+$ ]]; then continue; fi

    html_progress "${mount_point} (${fs}) - ${used}/${size}" "$pct"
done <<< "$(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2 | grep -vE '^tmpfs|^devtmpfs|^none|^udev|^shm')"

html_cmd_output "df -h" "$df_h_out"
html_cmd_output "lsblk" "$lsblk_out"
[ -n "$fdisk_out" ] && html_cmd_output "fdisk -l" "$fdisk_out"
html_cmd_output "mount" "$mount_out"
html_section_close

# 5. LVM
pv_out="" ; vg_out="" ; lv_out=""
command -v pvdisplay >/dev/null 2>&1 && pv_out=$(pvdisplay 2>/dev/null)
command -v vgdisplay >/dev/null 2>&1 && vg_out=$(vgdisplay 2>/dev/null)
command -v lvdisplay >/dev/null 2>&1 && lv_out=$(lvdisplay 2>/dev/null)
txt_header "LVM"
[ -n "$pv_out" ] && txt_cmd "pvdisplay" "$pv_out"
[ -n "$vg_out" ] && txt_cmd "vgdisplay" "$vg_out"
[ -n "$lv_out" ] && txt_cmd "lvdisplay" "$lv_out"
html_section_open "lvm" "LVM"
[ -n "$pv_out" ] && html_cmd_output "pvdisplay" "$pv_out"
[ -n "$vg_out" ] && html_cmd_output "vgdisplay" "$vg_out"
[ -n "$lv_out" ] && html_cmd_output "lvdisplay" "$lv_out"
if [ -z "$pv_out" ] && [ -z "$vg_out" ] && [ -z "$lv_out" ]; then html_raw '<p class="badge badge-info">No LVM volumes found</p>'; fi
html_section_close

# 6. FILESYSTEM
fstab_out="" ; hosts_out=""
[ -f /etc/fstab ] && fstab_out=$(cat /etc/fstab)
[ -f /etc/hosts ] && hosts_out=$(cat /etc/hosts)
txt_header "FILESYSTEM"
[ -n "$hosts_out" ] && txt_cmd "/etc/hosts" "$hosts_out"
[ -n "$fstab_out" ] && txt_cmd "/etc/fstab" "$fstab_out"
html_section_open "filesystem" "Filesystem"
[ -n "$fstab_out" ] && html_cmd_output "cat /etc/fstab" "$fstab_out"
[ -n "$hosts_out" ] && html_cmd_output "cat /etc/hosts" "$hosts_out"
html_section_close

# 7. MEMORY
free_out=$(free -h 2>/dev/null)
meminfo_out=$(cat /proc/meminfo 2>/dev/null)
mem_total=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
mem_available=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
mem_free=$(grep MemFree /proc/meminfo 2>/dev/null | awk '{print $2}')
mem_pct=0
if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ] 2>/dev/null; then
    if [ -n "$mem_available" ]; then mem_used=$((mem_total - mem_available))
    else mem_used=$((mem_total - mem_free)) ; fi
    mem_pct=$((mem_used * 100 / mem_total))
fi
txt_header "MEMORY"
txt_cmd "free -h" "$free_out"
txt_cmd "/proc/meminfo" "$meminfo_out"
html_section_open "memory" "Memory Usage"
html_progress "Memory Usage" "$mem_pct"
html_cmd_output "free -h" "$free_out"
html_section_close

# 8. PERFORMANCE
w_out=$(w 2>/dev/null)
top_out=$(top -b -n1 2>/dev/null | head -30)
txt_header "PERFORMANCE"
txt_cmd "w" "$w_out"
txt_cmd "top -b -n1" "$top_out"
html_section_open "performance" "Performance"
html_cmd_output "w" "$w_out"
html_cmd_output "top -b -n1" "$top_out"
html_section_close

# 9. NETWORK
ip_addr_out=$(get_ip_addresses)
ip_route_out=$(get_routes)
txt_header "NETWORK"
txt_cmd "Network Addr" "$ip_addr_out"
txt_cmd "Routing" "$ip_route_out"
html_section_open "network" "Network"
html_cmd_output "Addresses" "$ip_addr_out"
html_cmd_output "Routes" "$ip_route_out"
html_section_close

# 10. NETWORK CONFIGURATION
txt_header "NETWORK CONFIGURATION"
html_section_open "network-config" "Network Configuration"
if [ -d /etc/sysconfig/network-scripts ]; then
    for f in /etc/sysconfig/network-scripts/ifcfg-* /etc/sysconfig/network-scripts/route-* /etc/sysconfig/network-scripts/rule-*; do
        if [ -f "$f" ]; then
            txt_cmd "$f" "$(cat "$f")"
            html_cmd_output "cat $f" "$(cat "$f")"
        fi
    done
fi
if [ -d /etc/NetworkManager/system-connections ]; then
    for f in /etc/NetworkManager/system-connections/*; do
        if [ -f "$f" ]; then
            txt_cmd "$f" "$(cat "$f")"
            html_cmd_output "cat $f" "$(cat "$f")"
        fi
    done
fi
html_section_close

# 11. BOND STATUS
txt_header "BOND STATUS"
html_section_open "bonding" "Bond Status"
bond_found=false
for bond_file in /proc/net/bonding/bond*; do
    if [ -f "$bond_file" ]; then
        bond_found=true
        txt_cmd "$(basename "$bond_file")" "$(cat "$bond_file")"
        html_cmd_output "cat $bond_file" "$(cat "$bond_file")"
    fi
done
[ "$bond_found" = false ] && html_raw '<p class="badge badge-info">No bonding interfaces found</p>'
html_section_close

# 12. ROUTING
txt_header "ROUTING"
txt_cmd "Routing Table" "$ip_route_out"
html_section_open "routing" "Routing Table"
html_cmd_output "ip route" "$ip_route_out"
html_section_close

# 13. DNS
resolv_out=""
[ -f /etc/resolv.conf ] && resolv_out=$(grep -Ev '^\s*#|^\s*$' /etc/resolv.conf)
txt_header "DNS"
txt_cmd "/etc/resolv.conf" "$resolv_out"
html_section_open "dns" "DNS"
html_cmd_output "grep -Ev '^\s*#|^\s*$' /etc/resolv.conf" "$resolv_out"
html_section_close

# 14. FIREWALL
txt_header "FIREWALL"
html_section_open "firewall" "Firewall"
if [ "$USE_FIREWALLD" = true ]; then
    html_cmd_output "systemctl status firewalld" "$(systemctl status firewalld --no-pager 2>&1)"
elif [ "$USE_UFW" = true ]; then
    html_cmd_output "ufw status" "$(ufw status 2>&1)"
else
    html_cmd_output "iptables" "$(service iptables status 2>&1 || iptables -L -n 2>&1)"
fi
html_section_close

# 15. SELINUX
txt_header "SELINUX"
html_section_open "selinux" "SELinux"
if command -v sestatus >/dev/null 2>&1; then
    se_out=$(sestatus 2>/dev/null)
    txt_cmd "sestatus" "$se_out"
    html_cmd_output "sestatus" "$se_out"
else
    html_raw '<p class="badge badge-info">SELinux not available</p>'
fi
html_section_close

# 16. NTP
txt_header "NTP"
html_section_open "ntp" "NTP / Chrony"
if command -v ntpq >/dev/null 2>&1; then html_cmd_output "ntpq -p" "$(ntpq -p 2>&1)" ; fi
if command -v chronyc >/dev/null 2>&1; then html_cmd_output "chronyc tracking" "$(chronyc tracking 2>&1)" ; fi
html_section_close

# 17. LISTENING PORTS
ports_out=$(get_listening_ports)
txt_header "LISTENING PORTS"
txt_cmd "Listening Ports" "$ports_out"
html_section_open "ports" "Listening Ports"
html_cmd_output "Listening Ports" "$ports_out"
html_section_close

# 18. SERVICES
txt_header "SERVICES"
html_section_open "services" "Services"
for svc_name in $CHECK_SERVICES; do
    svc_res=$(check_service_status "$svc_name")
    svc_st=$(echo "$svc_res" | cut -d'|' -f1)
    svc_op=$(echo "$svc_res" | cut -d'|' -f2-)
    txt_cmd "Service: $svc_name ($svc_st)" "$svc_op"
    html_cmd_output "Service: $svc_name ($svc_st)" "$svc_op"
done
html_section_close

# 19. EXPORTS
txt_header "NFS EXPORTS"
html_section_open "exports" "NFS Exports"
if [ -f /etc/exports ]; then html_cmd_output "cat /etc/exports" "$(cat /etc/exports)"
else html_raw '<p class="badge badge-info">No /etc/exports found</p>' ; fi
html_section_close

# 20. CRON
crontab_out=$(crontab -l 2>/dev/null || echo "No user crontab")
txt_header "CRON"
txt_cmd "crontab -l" "$crontab_out"
html_section_open "cron" "Cron Jobs"
html_cmd_output "crontab -l" "$crontab_out"
html_section_close

# 21. SYSCTL
sysctl_out=""
[ -f /etc/sysctl.conf ] && sysctl_out=$(grep -Ev '^\s*#|^\s*$' /etc/sysctl.conf)
txt_header "SYSCTL"
txt_cmd "/etc/sysctl.conf (active)" "$sysctl_out"
html_section_open "sysctl" "Sysctl Configuration"
html_cmd_output "cat /etc/sysctl.conf (comments removed)" "$sysctl_out"
html_section_close

# 22. LIMITS
limits_out=""
[ -f /etc/security/limits.conf ] && limits_out=$(cat /etc/security/limits.conf)
txt_header "LIMITS"
txt_cmd "limits.conf" "$limits_out"
html_section_open "limits" "Limits"
html_cmd_output "cat /etc/security/limits.conf" "$limits_out"
html_section_close

# 23. MULTIPATH
txt_header "MULTIPATH"
html_section_open "multipath" "Multipath"
if command -v multipath >/dev/null 2>&1; then html_cmd_output "multipath -ll" "$(multipath -ll 2>&1)" ; fi
[ -f /etc/multipath.conf ] && html_cmd_output "cat /etc/multipath.conf" "$(cat /etc/multipath.conf)"
html_section_close

# 24. HOME DIRECTORY / USERS
home_out=$(ls -l /home 2>/dev/null)
txt_header "HOME DIRECTORY"
txt_cmd "ls -l /home" "$home_out"
html_section_open "users" "Home Directory"
html_cmd_output "ls -l /home" "$home_out"
html_section_close

# FINALIZE REPORT
html_report_end

# GENERATE JSON REPORT FOR DASHBOARD COMPARISON
generate_json_report() {
    local ram_total ram_used ram_pct swap_total swap_used swap_pct
    ram_total=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    ram_used=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}')
    ram_pct=$(free 2>/dev/null | awk '/^Mem:/{if($2>0) printf "%.1f%%", ($3/$2)*100; else print "0%"}')

    swap_total=$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')
    swap_used=$(free -h 2>/dev/null | awk '/^Swap:/{print $3}')
    swap_pct=$(free 2>/dev/null | awk '/^Swap:/{if($2>0) printf "%.1f%%", ($3/$2)*100; else print "0%"}')

    local selinux_status="Disabled"
    if command -v sestatus >/dev/null 2>&1; then
        selinux_status=$(sestatus 2>/dev/null | awk -F: '/Current mode:/{gsub(/[ \t]/, "", $2); print $2}')
        [ -z "$selinux_status" ] && selinux_status="Disabled"
    fi

    local ntp_status="Not Synchronized"
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl 2>/dev/null | grep -qi "NTP service: active\|System clock synchronized: yes"; then
            ntp_status="Synchronized"
        fi
    fi

    local sshd_st docker_st nginx_st chrony_st multi_st
    sshd_st=$(check_service_status sshd | cut -d'|' -f1 | tr -d '\r\n')
    docker_st=$(check_service_status docker | cut -d'|' -f1 | tr -d '\r\n')
    nginx_st=$(check_service_status nginx | cut -d'|' -f1 | tr -d '\r\n')
    chrony_st=$(check_service_status chronyd | cut -d'|' -f1 | tr -d '\r\n')
    multi_st=$(check_service_status multipathd | cut -d'|' -f1 | tr -d '\r\n')

    export PY_HOSTNAME="${CURRENT_HOSTNAME}"
    export PY_FQDN="${CURRENT_FQDN}"
    export PY_IP="${CURRENT_IP}"
    export PY_OS="${OS_FULL}"
    export PY_KERNEL="${CURRENT_KERNEL}"
    export PY_CPU_CORES="${CURRENT_NPROC}"
    export PY_RAM_TOTAL="${ram_total:-N/A}"
    export PY_RAM_USED="${ram_used:-N/A}"
    export PY_RAM_PCT="${ram_pct:-0%}"
    export PY_SWAP_TOTAL="${swap_total:-N/A}"
    export PY_SWAP_USED="${swap_used:-N/A}"
    export PY_SWAP_PCT="${swap_pct:-0%}"
    export PY_UPTIME="${CURRENT_UPTIME}"
    export PY_SSHD="${sshd_st}"
    export PY_DOCKER="${docker_st}"
    export PY_NGINX="${nginx_st}"
    export PY_CHRONYD="${chrony_st}"
    export PY_MULTIPATHD="${multi_st}"
    export PY_SELINUX="${selinux_status}"
    export PY_NTP="${ntp_status}"

    # Use Python json.dumps() with quoted heredoc to guarantee RFC8259 compliance
    if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
        PY_CMD=$(command -v python3 || command -v python)
        $PY_CMD - << 'PYEOF' > "$JSON_REPORT"
import json
import subprocess
import os

def clean_val(key, default="N/A"):
    val = os.environ.get(key, default)
    if not val:
        return default
    return val.strip()

def get_df():
    filesystems = []
    try:
        out = subprocess.check_output("df -P -h 2>/dev/null", shell=True, text=True)
        lines = out.strip().split('\n')[1:]
        for line in lines:
            parts = line.split()
            if len(parts) >= 6:
                filesystems.append({
                    "filesystem": parts[0],
                    "size": parts[1],
                    "used": parts[2],
                    "avail": parts[3],
                    "use_pct": parts[4],
                    "mount": parts[5]
                })
    except Exception:
        pass
    return filesystems

def get_ips():
    ips = []
    try:
        out = subprocess.check_output("ip -o addr show 2>/dev/null", shell=True, text=True)
        for line in out.strip().split('\n'):
            parts = line.split()
            if len(parts) >= 4:
                ips.append(f"{parts[1]} {parts[3]}")
    except Exception:
        pass
    return ips

def get_routes():
    routes = []
    try:
        out = subprocess.check_output("route -n 2>/dev/null || ip route 2>/dev/null", shell=True, text=True)
        lines = out.strip().split('\n')
        for line in lines:
            line_str = line.strip()
            if line_str and not line_str.startswith("Kernel IP") and not line_str.startswith("Destination"):
                routes.append(line_str)
    except Exception:
        pass
    return routes

data = {
    "system": {
        "hostname": clean_val("PY_HOSTNAME"),
        "fqdn": clean_val("PY_FQDN"),
        "ip": clean_val("PY_IP"),
        "os": clean_val("PY_OS"),
        "kernel": clean_val("PY_KERNEL"),
        "cpu_cores": clean_val("PY_CPU_CORES"),
        "ram_total": clean_val("PY_RAM_TOTAL"),
        "uptime": clean_val("PY_UPTIME")
    },
    "storage": {
        "filesystems": get_df()
    },
    "memory": {
        "ram_total": clean_val("PY_RAM_TOTAL"),
        "ram_used": clean_val("PY_RAM_USED"),
        "ram_used_pct": clean_val("PY_RAM_PCT", "0%"),
        "swap_total": clean_val("PY_SWAP_TOTAL"),
        "swap_used": clean_val("PY_SWAP_USED"),
        "swap_used_pct": clean_val("PY_SWAP_PCT", "0%")
    },
    "services": {
        "sshd": clean_val("PY_SSHD"),
        "docker": clean_val("PY_DOCKER"),
        "nginx": clean_val("PY_NGINX"),
        "chronyd": clean_val("PY_CHRONYD"),
        "multipathd": clean_val("PY_MULTIPATHD")
    },
    "network": {
        "ip_addresses": get_ips(),
        "routes": get_routes()
    },
    "security": {
        "selinux": clean_val("PY_SELINUX", "Disabled"),
        "ntp": clean_val("PY_NTP", "Not Synchronized")
    }
}

print(json.dumps(data, indent=2))
PYEOF
    fi

    # Immediate RFC8259 Validation Step
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$JSON_REPORT" >/dev/null 2>&1; then
            echo "[ERROR] Generated JSON failed validation: $JSON_REPORT"
            rm -f "$JSON_REPORT"
        else
            echo "[INFO] JSON report validated successfully (RFC8259 compliant)."
        fi
    fi
}

generate_json_report

echo ""
echo "Health check complete. Reports saved:"
echo " TXT  : $TXT_REPORT"
echo " HTML : $HTML_REPORT"
echo " JSON : $JSON_REPORT"

# AUTOMATIC UPLOAD VIA CURL
echo ""
echo "===================================================="
echo "Uploading reports to central server..."
echo "===================================================="

for RFILE in "$HTML_REPORT" "$TXT_REPORT" "$JSON_REPORT"; do
    if [ -f "$RFILE" ]; then
        attempt=0
        upload_success=false

        while [ $attempt -lt "$UPLOAD_RETRIES" ]; do
            attempt=$((attempt + 1))
            echo "[INFO] Uploading $(basename "$RFILE") (attempt ${attempt}/${UPLOAD_RETRIES}) to ${UPLOAD_URL}..."

            RESPONSE=$(curl -s -w "\n%{http_code}" \
                --connect-timeout "$UPLOAD_TIMEOUT" \
                --max-time "$UPLOAD_TIMEOUT" \
                -F "hostname=${CURRENT_HOSTNAME}" \
                -F "file=@${RFILE}" \
                "${UPLOAD_URL}" 2>&1)

            HTTP_CODE=$(echo "$RESPONSE" | tail -1)
            BODY=$(echo "$RESPONSE" | sed '$d')

            if [ "$HTTP_CODE" = "200" ] || echo "$BODY" | grep -qi "Upload Successful"; then
                echo "[INFO] $(basename "$RFILE") uploaded successfully."
                upload_success=true
                break
            else
                echo "[WARN] Upload failed for $(basename "$RFILE") (HTTP ${HTTP_CODE})"
                if [ $attempt -lt "$UPLOAD_RETRIES" ]; then
                    sleep "$UPLOAD_RETRY_DELAY"
                fi
            fi
        done

        if [ "$upload_success" = false ]; then
            echo "[ERROR] Upload failed for $(basename "$RFILE") after ${UPLOAD_RETRIES} attempts."
        fi
    fi
done

exit 0
