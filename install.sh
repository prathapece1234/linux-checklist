#!/bin/bash
# =============================================================================
# Enterprise Linux Health Dashboard - Production Installation Script
# =============================================================================
# Designed for production Linux servers (OpsRamp Gateway, RHEL, Ubuntu).
#
# Key Features:
#   - Zero disruption to existing production services (Nginx, OpsRamp, Docker)
#   - Runs Flask API inside a Python Virtual Environment (/opt/health-dashboard/venv)
#   - Dedicated unprivileged system account (healthdashboard)
#   - Strict Port pre-check (5000, 8088) with immediate exit if occupied
#   - Non-destructive Nginx configuration with reload-only (never restart)
#   - Systemd security hardening (NoNewPrivileges, PrivateTmp, ProtectSystem)
#   - Detailed logging to /var/log/health-dashboard/installation.log
#   - Comprehensive post-install PASS/FAIL validation matrix
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
# 1. EXISTING PRODUCTION SERVICES INSPECTION
# =============================================================================
echo ""
echo "[Step 1/12] Inspecting Existing Production Environment..."

check_prod_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "[INFO] Detected active production service: ${svc} (Running)"
    else
        echo "[INFO] Production service status: ${svc} (Not running / Not present)"
    fi
}

check_prod_service "nginx"
check_prod_service "apache2"
check_prod_service "docker"
check_prod_service "opsramp-agent"
check_prod_service "opsramp-gateway"

# =============================================================================
# 2. STRICT PORT CHECK (5000 & 8088)
# =============================================================================
echo ""
echo "[Step 2/12] Verifying Target Ports (${API_PORT} & ${DASHBOARD_PORT})..."

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
    echo "[FATAL ERROR] Port ${API_PORT} is already in use by another process!"
    echo "              Installation STOPPED to prevent production conflict."
    exit 1
fi

if is_port_in_use "$DASHBOARD_PORT"; then
    echo "[FATAL ERROR] Port ${DASHBOARD_PORT} is already in use by another process!"
    echo "              Installation STOPPED to prevent production conflict."
    exit 1
fi

echo "[INFO] Ports ${API_PORT} and ${DASHBOARD_PORT} are available."

# =============================================================================
# 3. MISSING PACKAGE INSTALLATION (IDEMPOTENT)
# =============================================================================
echo ""
echo "[Step 3/12] Checking Required System Packages..."

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
        echo "[INFO] Installing missing package '$pkg'..."
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
install_if_missing "nginx" "nginx"

# =============================================================================
# 4. DEDICATED UNPRIVILEGED SERVICE ACCOUNT
# =============================================================================
echo ""
echo "[Step 4/12] Configuring Dedicated Service Account (${SERVICE_USER})..."

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

# =============================================================================
# 5. DIRECTORY STRUCTURE CREATION
# =============================================================================
echo ""
echo "[Step 5/12] Setting Up Directory Paths..."

mkdir -p "${APP_DIR}/upload"
mkdir -p "${APP_DIR}/templates"
mkdir -p "${WEB_ROOT}/static"
mkdir -p "${LOG_DIR}"

# =============================================================================
# 6. PYTHON VIRTUAL ENVIRONMENT
# =============================================================================
echo ""
echo "[Step 6/12] Configuring Python Virtual Environment (${VENV_DIR})..."

if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
    echo "[INFO] Created virtual environment at ${VENV_DIR}."
else
    echo "[INFO] Virtual environment already exists at ${VENV_DIR}."
fi

# Upgrade pip and install Flask & Gunicorn inside venv
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip setuptools
"${VENV_DIR}/bin/pip" install --quiet flask gunicorn

echo "[INFO] Installed dependencies inside venv:"
"${VENV_DIR}/bin/pip" list | grep -E "Flask|gunicorn|pip"

# =============================================================================
# 7. COPY APPLICATION FILES
# =============================================================================
echo ""
echo "[Step 7/12] Copying Application Source Files..."

cp -r "${SCRIPT_DIR}/upload/"* "${APP_DIR}/upload/"
cp -r "${SCRIPT_DIR}/templates/"* "${APP_DIR}/templates/"

# Ensure scripts have execute permissions
chmod 755 "${APP_DIR}/upload/upload.py"
chmod 755 "${APP_DIR}/upload/generate_dashboard.py"

# =============================================================================
# 8. PERMISSIONS & OWNERSHIP (STRICT 755 / 644)
# =============================================================================
echo ""
echo "[Step 8/12] Applying Strict Security Permissions..."

# Assign ownership to healthdashboard user
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${WEB_ROOT}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${LOG_DIR}"

# Directory permissions (755) and File permissions (644)
find "${APP_DIR}" -type d -exec chmod 755 {} +
find "${APP_DIR}" -type f -exec chmod 644 {} +
chmod 755 "${APP_DIR}/upload/upload.py" "${APP_DIR}/upload/generate_dashboard.py"

find "${WEB_ROOT}" -type d -exec chmod 755 {} +
find "${WEB_ROOT}" -type f -exec chmod 644 {} +

# =============================================================================
# 9. NGINX CONFIGURATION (NON-DESTRUCTIVE, RELOAD ONLY)
# =============================================================================
echo ""
echo "[Step 9/12] Configuring Nginx Site..."

NGINX_CONF_TARGET=""
if [ -d /etc/nginx/conf.d ]; then
    NGINX_CONF_TARGET="/etc/nginx/conf.d/health-dashboard.conf"
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" "$NGINX_CONF_TARGET"
elif [ -d /etc/nginx/sites-available ]; then
    NGINX_CONF_TARGET="/etc/nginx/sites-available/health-dashboard.conf"
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" "$NGINX_CONF_TARGET"
    ln -sf "$NGINX_CONF_TARGET" /etc/nginx/sites-enabled/
fi

echo "[INFO] Testing Nginx configuration syntax..."
nginx -t

echo "[INFO] Reloading Nginx (Reloading configuration without interrupting existing traffic)..."
systemctl reload nginx

# =============================================================================
# 10. SYSTEMD SERVICE HARDENING
# =============================================================================
echo ""
echo "[Step 10/12] Deploying Hardened Systemd Service (health-dashboard-api.service)..."

cat << EOF > /etc/systemd/system/health-dashboard-api.service
[Unit]
Description=Enterprise Linux Health Dashboard Upload API
After=network.target
Documentation=https://github.com/Prathaps8675/linux-checklist

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${APP_DIR}/upload
ExecStart=${VENV_DIR}/bin/python upload.py
Restart=always
RestartSec=5

# Security Hardening Settings
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

# =============================================================================
# 11. INITIAL DASHBOARD GENERATION
# =============================================================================
echo ""
echo "[Step 11/12] Initializing Central Dashboard Page..."

sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/python" "${APP_DIR}/upload/generate_dashboard.py" "${WEB_ROOT}"

# =============================================================================
# 12. FINAL VALIDATION MATRIX (PASS / FAIL)
# =============================================================================
echo ""
echo "[Step 12/12] Running Final Installation Validation Matrix..."
echo "------------------------------------------------------------"

VAL_VENV="FAIL"
VAL_FLASK_SVC="FAIL"
VAL_NGINX_SVC="FAIL"
VAL_API_HTTP="FAIL"
VAL_DASH_HTTP="FAIL"

# Check 1: Virtual environment check
if "${VENV_DIR}/bin/python" -c "import flask, gunicorn" >/dev/null 2>&1; then
    VAL_VENV="PASS"
fi

# Check 2: Systemd service active check
if systemctl is-active --quiet health-dashboard-api; then
    VAL_FLASK_SVC="PASS"
fi

# Check 3: Nginx service active check
if systemctl is-active --quiet nginx; then
    VAL_NGINX_SVC="PASS"
fi

# Check 4: Upload API reachable on 5000
sleep 2
HTTP_API=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${API_PORT}/health" 2>/dev/null || echo "000")
if [ "$HTTP_API" = "200" ]; then
    VAL_API_HTTP="PASS"
fi

# Check 5: Dashboard reachable on 8088
HTTP_DASH=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${DASHBOARD_PORT}/" 2>/dev/null || echo "000")
if [ "$HTTP_DASH" = "200" ] || [ "$HTTP_DASH" = "304" ]; then
    VAL_DASH_HTTP="PASS"
fi

echo ""
echo "============================================================"
echo "          INSTALLATION VALIDATION SUMMARY MATRIX"
echo "============================================================"
printf " %-45s [%s]\n" "Python Virtual Environment (/opt/health-dashboard/venv)" "$VAL_VENV"
printf " %-45s [%s]\n" "Flask API Systemd Service (healthdashboard user)" "$VAL_FLASK_SVC"
printf " %-45s [%s]\n" "Nginx Web Server Service" "$VAL_NGINX_SVC"
printf " %-45s [%s]\n" "Upload API Endpoint (http://127.0.0.1:5000/health)" "$VAL_API_HTTP"
printf " %-45s [%s]\n" "Dashboard UI Endpoint (http://127.0.0.1:8088/)" "$VAL_DASH_HTTP"
echo "============================================================"

# Final summary verdict
if [ "$VAL_VENV" = "PASS" ] && [ "$VAL_FLASK_SVC" = "PASS" ] && [ "$VAL_NGINX_SVC" = "PASS" ] && [ "$VAL_API_HTTP" = "PASS" ] && [ "$VAL_DASH_HTTP" = "PASS" ]; then
    echo ""
    echo "[SUCCESS] All validation checks PASSED!"
    echo "          Dashboard URL  : http://$(hostname -I 2>/dev/null | awk '{print $1}'):${DASHBOARD_PORT}"
    echo "          Upload API URL : http://$(hostname -I 2>/dev/null | awk '{print $1}'):${API_PORT}/upload"
    echo "          Installation Log: ${INSTALL_LOG}"
    echo "============================================================"
    exit 0
else
    echo ""
    echo "[WARNING] One or more validation checks FAILED."
    echo "          Check log file: ${INSTALL_LOG}"
    echo "          Or check service status: systemctl status health-dashboard-api"
    echo "============================================================"
    exit 1
fi
