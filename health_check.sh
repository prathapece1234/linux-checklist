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

        .top-nav {
            background: linear-gradient(90deg, #B71C1C 0%, #8E1720 20%, #1E1E24 45%, #183A6D 75%, #2563EB 100%);
            color: #ffffff;
            min-height: 100px;
            padding: 14px 30px;
            position: sticky;
            top: 0;
            z-index: 1000;
            box-shadow: 0 6px 20px rgba(0,0,0,0.25);
            backdrop-filter: blur(8px);
            border-bottom-left-radius: 12px;
            border-bottom-right-radius: 12px;
            display: flex;
            align-items: center;
        }
        .top-nav .nav-content {
            max-width: 1600px;
            margin: 0 auto;
            width: 100%;
            display: grid;
            grid-template-columns: 220px 1fr 220px;
            align-items: center;
        }
        .nav-left { display: flex; align-items: center; }
        .btn-back-dashboard {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            background: #ffffff;
            color: #1f2937 !important;
            border: 2px solid #ef5350;
            padding: 8px 18px;
            border-radius: 8px;
            font-size: 0.88em;
            font-weight: 700;
            text-decoration: none !important;
            transition: all 0.25s ease;
            box-shadow: 0 2px 6px rgba(0,0,0,0.1);
        }
        .btn-back-dashboard:hover {
            background: #d32f2f;
            color: #ffffff !important;
            border-color: #d32f2f;
            box-shadow: 0 4px 12px rgba(211, 47, 47, 0.4);
        }
        .nav-center { text-align: center; }
        .report-title-wrap {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
        }
        .report-title-icon { font-size: 1.5em; }
        .report-title-text {
            font-size: 32px;
            font-weight: 800;
            color: #ffffff;
            line-height: 1.2;
            letter-spacing: -0.5px;
        }
        .title-accent-line {
            height: 2px;
            width: 60px;
            background: #ef5350;
            margin: 6px auto 8px;
            border-radius: 1px;
        }
        .nav-meta-row {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 12px;
            flex-wrap: wrap;
            font-size: 15px;
            color: #e5e7eb;
        }
        .nav-meta-item strong { color: #ffffff; font-weight: 700; }
        .meta-separator { color: rgba(255,255,255,0.4); font-weight: 300; }
        .nav-right { width: 100%; }

        .page-layout { display: flex; min-height: calc(100vh - 100px); }

        .sidebar {
            position: sticky;
            top: 104px;
            width: 240px;
            min-width: 240px;
            height: calc(100vh - 104px);
            background: #fff;
            box-shadow: 2px 0 8px rgba(0,0,0,0.08);
            overflow-y: auto;
            padding: 15px 0;
        }
        .side-nav-title {
            font-size: 0.7em;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 1.5px;
            color: #999;
            padding: 12px 20px 6px;
        }
        .side-nav a {
            display: block;
            padding: 8px 20px;
            color: #555;
            font-size: 0.85em;
            border-left: 3px solid transparent;
            transition: all 0.2s ease;
        }
        .side-nav a:hover, .side-nav a.active {
            color: #4a6cf7;
            background: #f0f3ff;
            border-left-color: #4a6cf7;
            font-weight: 600;
        }

        .main-content {
            flex: 1;
            padding: 25px 30px;
            max-width: calc(100% - 240px);
        }

        .report-section { margin-bottom: 22px; }
        .section-header {
            background: #fff;
            padding: 14px 20px;
            border-radius: 10px 10px 0 0;
            border-left: 5px solid #4a6cf7;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 1px 4px rgba(0,0,0,0.06);
            user-select: none;
        }
        .section-header h3 { font-size: 1.05em; font-weight: 700; color: #2c3e50; }
        .header-right { display: flex; align-items: center; gap: 12px; }
        .toggle-icon { font-size: 0.9em; color: #999; transition: transform 0.3s; }
        .toggle-icon.collapsed { transform: rotate(-90deg); }
        .section-body {
            background: #fff;
            padding: 20px;
            border-radius: 0 0 10px 10px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.06);
            border-left: 5px solid #4a6cf7;
            border-top: 1px solid #f0f0f0;
        }
        .section-body.hidden { display: none; }

        .badge { display: inline-block; padding: 3px 14px; border-radius: 20px; font-size: 0.75em; font-weight: 700; text-transform: uppercase; }
        .badge-info { background: #d1ecf1; color: #0c5460; }
        .badge-success { background: #d4edda; color: #155724; }

        .table-responsive { overflow-x: auto; margin-bottom: 15px; }
        .table { width: 100%; border-collapse: collapse; font-size: 0.9em; }
        .table th { background: #f8f9fa; padding: 10px 14px; text-align: left; font-weight: 700; color: #555; border-bottom: 2px solid #dee2e6; }
        .table td { padding: 9px 14px; border-bottom: 1px solid #eee; }
        .table tr:hover { background: #f8f9ff; }
        .info-table th { width: 200px; background: #f0f3ff; color: #4a6cf7; }

        .progress-group { margin-bottom: 14px; }
        .progress-label { display: flex; justify-content: space-between; margin-bottom: 5px; font-size: 0.88em; }
        .progress-container { height: 22px; background: #e9ecef; border-radius: 11px; overflow: hidden; }
        .progress-bar { height: 100%; border-radius: 11px; display: flex; align-items: center; justify-content: center; font-size: 0.75em; font-weight: 700; color: #fff; background: linear-gradient(90deg, #4a6cf7, #6366f1); }

        .cmd-block { margin-bottom: 15px; }
        .cmd-label { font-size: 0.82em; font-weight: 700; color: #fff; background: #343a40; padding: 6px 14px; border-radius: 6px 6px 0 0; display: inline-block; }
        pre { background: #1e1e2e; color: #cdd6f4; padding: 15px 18px; border-radius: 0 6px 6px 6px; overflow-x: auto; font-size: 0.82em; font-family: monospace; margin: 0; white-space: pre-wrap; }

        .page-footer { text-align: center; padding: 25px; color: #888; font-size: 0.85em; background: #fff; border-top: 1px solid #eee; margin-top: 20px; }

        @media (max-width: 992px) {
            .top-nav .nav-content { grid-template-columns: 1fr; gap: 12px; text-align: center; }
            .nav-left { justify-content: center; }
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
                <a href="/" class="btn-back-dashboard">&larr; Back to Dashboard</a>
            </div>
            <div class="nav-center">
                <div class="report-title-wrap">
                    <span class="report-title-icon">&#x1F5A5;</span>
                    <h1 class="report-title-text">Linux Health Check Report</h1>
                </div>
                <div class="title-accent-line"></div>
                <div class="nav-meta-row">
                    <span class="nav-meta-item"><strong>Host:</strong> ${hostname_val}</span>
                    <span class="meta-separator">|</span>
                    <span class="nav-meta-item"><strong>OS:</strong> ${os_info}</span>
                    <span class="meta-separator">|</span>
                    <span class="nav-meta-item"><strong>Kernel:</strong> ${kernel}</span>
                    <span class="meta-separator">|</span>
                    <span class="nav-meta-item"><strong>IP:</strong> ${ip_addr}</span>
                    <span class="meta-separator">|</span>
                    <span class="nav-meta-item"><strong>Generated:</strong> ${report_date}</span>
                </div>
            </div>
            <div class="nav-right"></div>
        </div>
    </nav>
    <div class="page-layout">
    <aside class="sidebar">
        <nav class="side-nav">
            <div class="side-nav-title">System</div>
            <a href="#system-info">System Info</a>
            <a href="#hardware">Hardware</a>
            <a href="#kernel">Kernel</a>
            <div class="side-nav-title">Storage</div>
            <a href="#disk">Disk Usage</a>
            <a href="#lvm">LVM</a>
            <a href="#filesystem">Filesystem</a>
            <a href="#multipath">Multipath</a>
            <div class="side-nav-title">Memory</div>
            <a href="#memory">Memory</a>
            <a href="#performance">Performance</a>
            <div class="side-nav-title">Network</div>
            <a href="#network">Network</a>
            <a href="#network-config">Network Config</a>
            <a href="#bonding">Bond Status</a>
            <a href="#routing">Routing</a>
            <a href="#dns">DNS</a>
            <a href="#ports">Listening Ports</a>
            <div class="side-nav-title">Security</div>
            <a href="#firewall">Firewall</a>
            <a href="#selinux">SELinux</a>
            <div class="side-nav-title">Services</div>
            <a href="#ntp">NTP</a>
            <a href="#services">Services</a>
            <a href="#exports">NFS Exports</a>
            <div class="side-nav-title">Config & Users</div>
            <a href="#cron">Cron</a>
            <a href="#sysctl">Sysctl</a>
            <a href="#limits">Limits</a>
            <a href="#users">Home Directory</a>
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

    local selinux_status="N/A"
    if command -v sestatus >/dev/null 2>&1; then
        selinux_status=$(sestatus 2>/dev/null | awk -F: '/Current mode:/{gsub(/[ \t]/, "", $2); print $2}')
    fi

    local ntp_status="Not Synchronized"
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl 2>/dev/null | grep -qi "NTP service: active\|System clock synchronized: yes"; then
            ntp_status="Synchronized"
        fi
    fi

    cat << EOF > "$JSON_REPORT"
{
  "system": {
    "hostname": "${CURRENT_HOSTNAME}",
    "fqdn": "${CURRENT_FQDN}",
    "ip": "${CURRENT_IP}",
    "os": "${OS_FULL}",
    "kernel": "${CURRENT_KERNEL}",
    "cpu_cores": "${CURRENT_NPROC}",
    "ram_total": "${ram_total:-N/A}",
    "uptime": "${CURRENT_UPTIME}"
  },
  "storage": {
    "filesystems": [
$(df -P -h 2>/dev/null | awk 'NR>1 {printf "      {\"filesystem\":\"%s\",\"size\":\"%s\",\"used\":\"%s\",\"avail\":\"%s\",\"use_pct\":\"%s\",\"mount\":\"%s\"},\n", $1,$2,$3,$4,$5,$6}' | sed '$ s/,$//')
    ]
  },
  "memory": {
    "ram_total": "${ram_total:-N/A}",
    "ram_used": "${ram_used:-N/A}",
    "ram_used_pct": "${ram_pct:-0%}",
    "swap_total": "${swap_total:-N/A}",
    "swap_used": "${swap_used:-N/A}",
    "swap_used_pct": "${swap_pct:-0%}"
  },
  "services": {
    "sshd": "$(check_service_status sshd | cut -d'|' -f1)",
    "docker": "$(check_service_status docker | cut -d'|' -f1)",
    "nginx": "$(check_service_status nginx | cut -d'|' -f1)",
    "chronyd": "$(check_service_status chronyd | cut -d'|' -f1)",
    "multipathd": "$(check_service_status multipathd | cut -d'|' -f1)"
  },
  "network": {
    "ip_addresses": [
$(ip -o addr show 2>/dev/null | awk '{printf "      \"%s %s\",\n", $2, $4}' | sed '$ s/,$//')
    ],
    "routes": [
$(route -n 2>/dev/null | awk 'NR>2 {printf "      \"%s netmask %s gw %s dev %s\",\n", $1,$3,$2,$8}' | sed '$ s/,$//')
    ]
  },
  "security": {
    "selinux": "${selinux_status:-Disabled}",
    "ntp": "${ntp_status}"
  }
}
EOF
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

for RFILE in "$HTML_REPORT" "$JSON_REPORT"; do
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
