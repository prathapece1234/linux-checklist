#!/bin/bash
# =============================================================================
# Enterprise Linux Health Dashboard - Production Installation Script
# =============================================================================
# Designed for production Linux servers (OpsRamp Gateway, RHEL, Ubuntu).
# Preserves all existing services without disruption.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="/var/www/html/health-reports"
APP_DIR="/opt/health-dashboard"
VENV_DIR="${APP_DIR}/venv"
LOG_DIR="/var/log/health-dashboard"
INSTALL_LOG="${LOG_DIR}/installation.log"

SERVICE_USER="healthdashboard"
SERVICE_GROUP="healthdashboard"

API_PORT="5000"
DASHBOARD_PORT="8088"

# Setup logging directory and dual-logging to stdout + logfile
mkdir -p "${LOG_DIR}" 2>/dev/null || true
exec > >(tee -a "${INSTALL_LOG}") 2>&1

echo "============================================================"
echo " Enterprise Linux Health Dashboard Installation"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo " Server Hostname: $(hostname 2>/dev/null || echo 'unknown')"
echo "============================================================"

# Ensure root execution
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Installation must be executed as root."
    exit 1
fi

# =============================================================================
# 1. STRICT PRE-CHECK: VERIFY TARGET PORTS (5000 & 8088)
# =============================================================================
echo ""
echo "[Step 1/10] Checking whether ports ${API_PORT} and ${DASHBOARD_PORT} are free..."

is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulnp 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i ":${port}" >/dev/null 2>&1 && return 0
    fi
    return 1
}

if is_port_in_use "$API_PORT"; then
    echo "[FATAL ERROR] Port ${API_PORT} already in use"
    echo "              Installation STOPPED to prevent service conflict."
    exit 1
fi

if is_port_in_use "$DASHBOARD_PORT"; then
    echo "[FATAL ERROR] Port ${DASHBOARD_PORT} already in use"
    echo "              Installation STOPPED to prevent service conflict."
    exit 1
fi

echo "[INFO] Ports ${API_PORT} and ${DASHBOARD_PORT} are free and available."

# =============================================================================
# 2. PACKAGE INSTALLATION (ONLY MISSING PACKAGES)
# =============================================================================
echo ""
echo "[Step 2/10] Checking and installing required packages..."

# Detect Package Manager
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
else
    echo "[FATAL ERROR] Package manager (apt/dnf/yum) not found."
    exit 1
fi

install_if_missing() {
    local pkg="$1"
    local cmd_check="${2:-$1}"

    if command -v "$cmd_check" >/dev/null 2>&1; then
        echo "[INFO] Package '$pkg' is already installed."
    else
        echo "[INFO] Package '$pkg' not found. Installing..."
        if [ "$PKG_MGR" = "apt" ]; then
            apt-get update -qq
            apt-get install -y --no-install-recommends "$pkg"
        else
            $PKG_MGR install -y "$pkg"
        fi
    fi
}

install_if_missing "python3" "python3"
if [ "$PKG_MGR" = "apt" ]; then
    install_if_missing "python3-venv" "python3"
    install_if_missing "python3-pip" "pip3"
fi

# Step 1 Check Nginx binary existence
if ! command -v nginx >/dev/null 2>&1; then
    echo "[INFO] Nginx binary not found. Installing Nginx..."
    install_if_missing "nginx" "nginx"
else
    echo "[INFO] Nginx binary is already installed."
fi

# =============================================================================
# 3. DEDICATED SERVICE ACCOUNT & DIRECTORY PATHS
# =============================================================================
echo ""
echo "[Step 3/10] Configuring Service Account (${SERVICE_USER}) and Directories..."

if getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    echo "[INFO] Group '${SERVICE_GROUP}' already exists."
else
    groupadd -r "$SERVICE_GROUP" 2>/dev/null || true
    echo "[INFO] Created system group '${SERVICE_GROUP}'."
fi

if id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "[INFO] User '${SERVICE_USER}' already exists."
else
    useradd -r \
        -g "$SERVICE_GROUP" \
        -d "$APP_DIR" \
        -s /usr/sbin/nologin \
        -c "Enterprise Health Dashboard Service Account" \
        "$SERVICE_USER"
    echo "[INFO] Created system user '${SERVICE_USER}'."
fi

mkdir -p "${APP_DIR}/upload"
mkdir -p "${APP_DIR}/templates"
mkdir -p "${WEB_ROOT}/static"
mkdir -p "${LOG_DIR}"

# =============================================================================
# 4. PYTHON VIRTUAL ENVIRONMENT
# =============================================================================
echo ""
echo "[Step 4/10] Setting Up Python Virtual Environment..."

if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
    echo "[INFO] Created Python venv at ${VENV_DIR}."
else
    echo "[INFO] Python venv already exists at ${VENV_DIR}."
fi

"${VENV_DIR}/bin/pip" install --quiet --upgrade pip setuptools
"${VENV_DIR}/bin/pip" install --quiet flask gunicorn

# =============================================================================
# 5. COPY APPLICATION FILES & APPLY STRICT PERMISSIONS
# =============================================================================
echo ""
echo "[Step 5/10] Copying Application Files & Applying Security Permissions..."

cp -r "${SCRIPT_DIR}/upload/"* "${APP_DIR}/upload/"
cp -r "${SCRIPT_DIR}/templates/"* "${APP_DIR}/templates/"

chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${WEB_ROOT}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${LOG_DIR}"

find "${APP_DIR}" -type d -exec chmod 755 {} +
find "${APP_DIR}" -type f -exec chmod 644 {} +
chmod 755 "${APP_DIR}/upload/upload.py" "${APP_DIR}/upload/generate_dashboard.py"

find "${WEB_ROOT}" -type d -exec chmod 755 {} +
find "${WEB_ROOT}" -type f -exec chmod 644 {} +

# =============================================================================
# 6. NGINX CONFIGURATION & VALIDATION
# =============================================================================
echo ""
echo "[Step 6/10] Deploying Nginx Site Configuration..."

if [ -d /etc/nginx/conf.d ]; then
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" /etc/nginx/conf.d/health-dashboard.conf
elif [ -d /etc/nginx/sites-available ]; then
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" /etc/nginx/sites-available/health-dashboard.conf
    ln -sf /etc/nginx/sites-available/health-dashboard.conf /etc/nginx/sites-enabled/health-dashboard.conf
fi

# Step 2: Validate Nginx syntax
echo "[INFO] Validating Nginx configuration syntax (nginx -t)..."
if ! nginx -t; then
    echo "[FATAL ERROR] Nginx configuration validation failed!"
    echo "              Installation STOPPED immediately."
    exit 1
fi
echo "[INFO] Nginx syntax check passed successfully."

# =============================================================================
# 7. NGINX SERVICE HANDLING (RELOAD IF ACTIVE, START IF INACTIVE, EXIT IF FAILED)
# =============================================================================
echo ""
echo "[Step 7/10] Managing Nginx Service State..."

NGINX_STATE=$(systemctl is-active nginx 2>/dev/null || echo "inactive")

case "$NGINX_STATE" in
    active)
        echo "[INFO] Nginx service is currently ACTIVE. Reloading configuration (systemctl reload nginx)..."
        systemctl reload nginx
        ;;
    inactive)
        echo "[INFO] Nginx service is currently INACTIVE. Starting and enabling Nginx..."
        systemctl start nginx
        systemctl enable nginx
        ;;
    failed)
        echo "[FATAL ERROR] Nginx service failed to start."
        echo "-------------- Nginx Journal Logs (Last 20 lines) --------------"
        journalctl -u nginx --no-pager -n 20 || true
        echo "----------------------------------------------------------------"
        exit 1
        ;;
    *)
        echo "[INFO] Starting and enabling Nginx service..."
        systemctl start nginx || true
        systemctl enable nginx || true
        ;;
esac

# =============================================================================
# 8. VERIFY DASHBOARD PORT LISTENING (PORT 8088)
# =============================================================================
echo ""
echo "[Step 8/10] Verifying Nginx is listening on Dashboard port ${DASHBOARD_PORT}..."

sleep 2

is_nginx_listening_dashboard() {
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | grep -E ":${DASHBOARD_PORT}\s" | grep -qi "nginx" && return 0
        ss -tulnp 2>/dev/null | grep -q -E ":${DASHBOARD_PORT}\s" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulnp 2>/dev/null | grep -q -E ":${DASHBOARD_PORT}\s" && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i ":${DASHBOARD_PORT}" >/dev/null 2>&1 && return 0
    fi
    return 1
}

if ! is_nginx_listening_dashboard; then
    echo "[FATAL ERROR] Nginx is NOT listening on Dashboard port ${DASHBOARD_PORT} after reload/start!"
    echo "              Checking Nginx error log:"
    tail -n 20 /var/log/nginx/error.log 2>/dev/null || true
    exit 1
fi

echo "[INFO] Verified: Nginx is actively listening on port ${DASHBOARD_PORT}."

# =============================================================================
# 9. FLASK SYSTEMD SERVICE DEPLOYMENT
# =============================================================================
echo ""
echo "[Step 9/10] Deploying Flask Upload API Systemd Service..."

cat << EOF > /etc/systemd/system/health-dashboard-api.service
[Unit]
Description=Enterprise Linux Health Dashboard Upload API
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${APP_DIR}/upload
ExecStart=${VENV_DIR}/bin/python upload.py
Restart=always
RestartSec=5

# Systemd Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

# Environment Variables
Environment=WEB_ROOT=${WEB_ROOT}
Environment=LISTEN_HOST=0.0.0.0
Environment=LISTEN_PORT=${API_PORT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable health-dashboard-api
systemctl restart health-dashboard-api

# Generate initial dashboard page
sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/python" "${APP_DIR}/upload/generate_dashboard.py" "${WEB_ROOT}"

# =============================================================================
# 10. FINAL VALIDATION & INSTALLATION SUMMARY MATRIX
# =============================================================================
echo ""
echo "[Step 10/10] Executing Final System Validation..."

VAL_NGINX_SVC="FAIL"
VAL_FLASK_SVC="FAIL"
VAL_PORT_DASH="FAIL"
VAL_PORT_API="FAIL"
VAL_OVERALL="FAIL"

# Check Nginx status
if systemctl is-active --quiet nginx; then
    VAL_NGINX_SVC="PASS"
fi

# Check Flask service status
if systemctl is-active --quiet health-dashboard-api; then
    VAL_FLASK_SVC="PASS"
fi

# Check Dashboard port
if is_nginx_listening_dashboard; then
    VAL_PORT_DASH="PASS"
fi

# Check API port
if is_port_in_use "$API_PORT"; then
    VAL_PORT_API="PASS"
fi

# Overall calculation
if [ "$VAL_NGINX_SVC" = "PASS" ] && [ "$VAL_FLASK_SVC" = "PASS" ] && [ "$VAL_PORT_DASH" = "PASS" ] && [ "$VAL_PORT_API" = "PASS" ]; then
    VAL_OVERALL="PASS"
fi

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")

echo ""
echo "============================================================"
echo "          INSTALLATION VALIDATION SUMMARY MATRIX"
echo "============================================================"
printf " Dashboard URL  : http://%s:%s/\n" "$SERVER_IP" "$DASHBOARD_PORT"
printf " Upload API URL : http://%s:%s/upload\n" "$SERVER_IP" "$API_PORT"
echo "------------------------------------------------------------"
printf " %-35s Status: [%s]\n" "Nginx Service" "$VAL_NGINX_SVC"
printf " %-35s Status: [%s]\n" "Flask API Service" "$VAL_FLASK_SVC"
printf " %-35s Status: [%s]\n" "Dashboard Port (${DASHBOARD_PORT})" "$VAL_PORT_DASH"
printf " %-35s Status: [%s]\n" "Upload API Port (${API_PORT})" "$VAL_PORT_API"
echo "------------------------------------------------------------"
printf " %-35s STATUS: [%s]\n" "OVERALL INSTALLATION" "$VAL_OVERALL"
echo "============================================================"

if [ "$VAL_OVERALL" = "PASS" ]; then
    echo "[SUCCESS] Installation completed successfully with zero issues."
    exit 0
else
    echo "[ERROR] Installation encountered errors. Please inspect ${INSTALL_LOG}."
    exit 1
fi
