#!/bin/bash
# =============================================================================
# Enterprise Linux Health Dashboard - Central Server Installation Script
# =============================================================================
# Installs Nginx, Python3, Flask, configures systemd services, and initializes
# the web root for the central Health Dashboard server.
#
# Supported OS: RHEL 7/8/9/10, Ubuntu 18/20/22/24
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="/var/www/html/health-reports"
APP_DIR="/opt/health-dashboard"

echo "============================================================"
echo " Enterprise Linux Health Dashboard Installation"
echo "============================================================"

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root."
    exit 1
fi

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

cat << 'EOF' > /etc/systemd/system/health-dashboard-api.service
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
Environment=LISTEN_PORT=5000

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
echo " Dashboard URL  : http://$(hostname -I | awk '{print $1}'):8088"
echo " Upload API URL : http://$(hostname -I | awk '{print $1}'):5000/upload"
echo "============================================================"
