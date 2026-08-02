#!/bin/bash
# =============================================================================
# Enterprise Linux Health Dashboard - Central Server Installation Script
# =============================================================================
# Installs Nginx, Python3, Flask, configures systemd services, and initializes
# the web root for the central Health Dashboard server.
#
# Default Ports Used:
#   - Port 5000 : Flask Upload API
#   - Port 8088 : Nginx Web Dashboard
#
# Supported OS: RHEL 7/8/9/10, Ubuntu 18/20/22/24
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="/var/www/html/health-reports"
APP_DIR="/opt/health-dashboard"

# Target Ports
API_PORT="5000"
DASHBOARD_PORT="8088"

echo "============================================================"
echo " Enterprise Linux Health Dashboard Installation"
echo "============================================================"

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root."
    exit 1
fi

# -----------------------------------------------------------------------------
# PRE-CHECK: Verify Ports 5000 and 8088 are free
# -----------------------------------------------------------------------------
echo "[0/5] Checking if ports ${API_PORT} and ${DASHBOARD_PORT} are available..."

check_port() {
    local port="$1"
    local service_name="$2"
    local port_in_use=false

    if command -v ss >/dev/null 2>&1; then
        if ss -tulnp | grep -q ":${port} "; then
            port_in_use=true
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tulnp | grep -q ":${port} "; then
            port_in_use=true
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i ":${port}" >/dev/null 2>&1; then
            port_in_use=true
        fi
    fi

    if [ "$port_in_use" = true ]; then
        echo "[WARNING] Port ${port} (${service_name}) is ALREADY IN USE on this server!"
        echo "          Please stop the service using port ${port} or change the port configuration."
        return 1
    else
        echo "[INFO] Port ${port} (${service_name}) is FREE."
        return 0
    fi
}

check_port "$API_PORT" "Flask Upload API" || true
check_port "$DASHBOARD_PORT" "Nginx Dashboard" || true

echo ""

# Detect Package Manager
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
else
    echo "[ERROR] Supported package manager (dnf/yum/apt-get) not found."
    exit 1
fi

echo "[1/5] Installing dependencies (Nginx, Python3, Flask)..."
if [ "$PKG_MGR" = "apt-get" ]; then
    apt-get update -y
    apt-get install -y nginx python3 python3-pip python3-flask
else
    $PKG_MGR install -y nginx python3 python3-pip || true
    pip3 install flask 2>/dev/null || $PKG_MGR install -y python3-flask
fi

echo "[2/5] Setting up directory structure..."
mkdir -p "${WEB_ROOT}/static"
mkdir -p "${APP_DIR}/upload"
mkdir -p "${APP_DIR}/templates"

echo "[3/5] Copying project files..."
cp -r "${SCRIPT_DIR}/upload/"* "${APP_DIR}/upload/"
cp -r "${SCRIPT_DIR}/templates/"* "${APP_DIR}/templates/"

chmod +x "${APP_DIR}/upload/upload.py"
chmod +x "${APP_DIR}/upload/generate_dashboard.py"

# Set permissions for web root
chown -R nginx:nginx "$WEB_ROOT" 2>/dev/null || chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null || chmod -R 755 "$WEB_ROOT"

echo "[4/5] Configuring Nginx & Systemd Service..."
if [ -d /etc/nginx/conf.d ]; then
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" /etc/nginx/conf.d/
elif [ -d /etc/nginx/sites-available ]; then
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" /etc/nginx/sites-available/
    ln -sf /etc/nginx/sites-available/health-dashboard.conf /etc/nginx/sites-enabled/
fi

nginx -t
systemctl restart nginx || service nginx restart

cat << EOF > /etc/systemd/system/health-dashboard-api.service
[Unit]
Description=Enterprise Linux Health Dashboard Upload API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/health-dashboard/upload
ExecStart=/usr/bin/python3 /opt/health-dashboard/upload/upload.py
Restart=always
RestartSec=5
Environment=WEB_ROOT=/var/www/html/health-reports
Environment=LISTEN_HOST=0.0.0.0
Environment=LISTEN_PORT=${API_PORT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable health-dashboard-api
systemctl restart health-dashboard-api

echo "[5/5] Initializing Dashboard..."
python3 "${APP_DIR}/upload/generate_dashboard.py" "${WEB_ROOT}"

echo "============================================================"
echo " Installation Complete!"
echo "============================================================"
echo " Dashboard URL  : http://$(hostname -I 2>/dev/null | awk '{print $1}'):${DASHBOARD_PORT}"
echo " Upload API URL : http://$(hostname -I 2>/dev/null | awk '{print $1}'):${API_PORT}/upload"
echo "============================================================"
