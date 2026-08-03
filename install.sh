#!/bin/bash
# =============================================================================
# Enterprise Linux Health Dashboard - Production Installation & Upgrade Script
# =============================================================================
# Installs or upgrades the dynamic Flask dashboard with Gunicorn behind Nginx.
# Designed for production Linux servers (OpsRamp Gateway, RHEL, Ubuntu).
# Preserves all existing services and uploaded reports without disruption.
#
# Usage:
#   sudo ./install.sh           (Interactive install / upgrade prompt)
#   sudo ./install.sh --upgrade (Non-interactive upgrade)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="/var/www/html/health-reports"
APP_DIR="/opt/health-dashboard"
VENV_DIR="${APP_DIR}/venv"
LOG_DIR="/var/log/health-dashboard"
INSTALL_LOG="${LOG_DIR}/installation.log"
ENV_FILE="${APP_DIR}/.env"
USERS_FILE="${APP_DIR}/users.json"

SERVICE_USER="healthdashboard"
SERVICE_GROUP="healthdashboard"

API_PORT="5000"
DASHBOARD_PORT="8088"

# Check CLI flags
IS_UPGRADE=false
for arg in "$@"; do
    case "$arg" in
        --upgrade|-u)
            IS_UPGRADE=true
            ;;
    esac
done

# Setup logging directory and dual-logging to stdout + logfile
mkdir -p "${LOG_DIR}" 2>/dev/null || true
exec > >(tee -a "${INSTALL_LOG}") 2>&1

echo "============================================================"
echo " Enterprise Linux Health Dashboard Installation & Upgrade"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo " Server Hostname: $(hostname 2>/dev/null || echo 'unknown')"
echo "============================================================"

# Ensure root execution
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Installation must be executed as root."
    exit 1
fi

# =============================================================================
# 1. PRE-CHECK: VERIFY PORTS & HANDLE UPGRADE MODE
# =============================================================================
echo ""
echo "[Step 1/11] Checking required ports and existing installation state..."

inspect_port() {
    local PORT="$1"
    local SERVICE_NAME="$2"

    if ss -tulpn 2>/dev/null | grep -q ":${PORT}\s"; then
        local PROCESS_INFO
        PROCESS_INFO=$(ss -tulpn 2>/dev/null | grep -E ":${PORT}\s" | head -1)

        echo "[INFO] Port ${PORT} (${SERVICE_NAME}) is currently IN USE."
        echo "       Running Process: ${PROCESS_INFO}"

        if echo "$PROCESS_INFO" | grep -qiE "upload.py|health-dashboard|python|gunicorn|flask"; then
            echo "[INFO] Recognized as existing Health Dashboard process."
            return 0
        elif [ "$PORT" = "$DASHBOARD_PORT" ] && echo "$PROCESS_INFO" | grep -qi nginx; then
            echo "[INFO] Recognized as existing Health Dashboard Nginx web server."
            return 0
        else
            echo ""
            echo "[FATAL ERROR] Port ${PORT} (${SERVICE_NAME}) is occupied by a FOREIGN application!"
            echo "              Process: ${PROCESS_INFO}"
            echo ""
            echo "[FATAL ERROR] Installation STOPPED immediately to prevent production service conflict."
            echo "              Please stop the conflicting application or change the configured port."
            exit 1
        fi
    else
        echo "[INFO] Port ${PORT} (${SERVICE_NAME}) is FREE."
        return 1
    fi
}

echo "[INFO] Inspecting Port ${API_PORT} (Upload API)..."
API_PORT_USED=$(inspect_port "$API_PORT" "Upload API" || echo "false")

echo "[INFO] Inspecting Port ${DASHBOARD_PORT} (Dashboard)..."
DASH_PORT_USED=$(inspect_port "$DASHBOARD_PORT" "Dashboard UI" || echo "false")

# Check for existing installation
EXISTING_FOUND=false
if [ "$API_PORT_USED" != "false" ] || [ "$DASH_PORT_USED" != "false" ] || [ -d "$APP_DIR/app" ] || [ -f "/etc/systemd/system/health-dashboard.service" ] || [ -f "/etc/systemd/system/health-dashboard-api.service" ]; then
    EXISTING_FOUND=true
fi

if [ "$EXISTING_FOUND" = true ]; then
    echo "[INFO] Existing Health Dashboard installation detected."

    if [ "$IS_UPGRADE" = true ]; then
        echo "[INFO] Upgrade mode enabled via flag (--upgrade)."
    elif [ -t 0 ]; then
        echo ""
        echo "============================================================"
        echo " Existing Health Dashboard Installation Detected!"
        echo "============================================================"
        echo " Choose action:"
        echo "   1) Upgrade existing installation (Update app files, venv & restart services)"
        echo "   2) Fresh installation (Reinstall & overwrite configs)"
        echo "   3) Exit / Cancel"
        echo "============================================================"
        read -rp "Select option [1-3]: " UPGRADE_CHOICE

        case "$UPGRADE_CHOICE" in
            1)
                IS_UPGRADE=true
                echo "[INFO] Proceeding with Upgrade..."
                ;;
            2)
                IS_UPGRADE=false
                echo "[INFO] Proceeding with Fresh Installation..."
                ;;
            3|*)
                echo "[INFO] Installation cancelled by user."
                exit 0
                ;;
        esac
    else
        # Non-interactive without --upgrade flag: default to upgrade
        IS_UPGRADE=true
        echo "[INFO] Non-interactive execution: automatically proceeding in Upgrade mode."
    fi
else
    echo "[INFO] Ports ${API_PORT} and ${DASHBOARD_PORT} are available. Starting fresh installation."
fi

# =============================================================================
# 2. PACKAGE INSTALLATION (ONLY MISSING PACKAGES)
# =============================================================================
echo ""
echo "[Step 2/11] Checking and installing required packages..."

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
echo "[Step 3/11] Configuring Service Account (${SERVICE_USER}) and Directories..."

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

mkdir -p "${APP_DIR}"
mkdir -p "${WEB_ROOT}/static"
mkdir -p "${LOG_DIR}"

# =============================================================================
# 4. PYTHON VIRTUAL ENVIRONMENT VALIDATION & REBUILD LOGIC
# =============================================================================
echo ""
echo "[Step 4/11] Validating Python Virtual Environment (${VENV_DIR})..."

if [ -d "${VENV_DIR}" ]; then
    if [ ! -x "${VENV_DIR}/bin/python" ] || [ ! -x "${VENV_DIR}/bin/pip" ]; then
        echo "[WARNING] Virtual environment at ${VENV_DIR} is corrupt."
        echo "[INFO] Rebuilding venv..."
        rm -rf "${VENV_DIR}"
    fi
fi

if [ ! -d "${VENV_DIR}" ]; then
    echo "[INFO] Creating new Python virtual environment..."
    python3 -m venv "${VENV_DIR}"
    echo "[INFO] Created Python venv at ${VENV_DIR}."
else
    echo "[INFO] Valid Python venv found at ${VENV_DIR}."
fi

echo "[INFO] Installing / Updating dependencies inside venv..."
"${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip setuptools
"${VENV_DIR}/bin/python" -m pip install --quiet flask gunicorn werkzeug

# =============================================================================
# 5. COPY APPLICATION FILES & SCOPED PERMISSIONS
# =============================================================================
echo ""
echo "[Step 5/11] Copying / Updating Application Source Files..."

# Clean old app code if present
rm -rf "${APP_DIR}/app" 2>/dev/null || true

# Copy Flask application package
cp -r "${SCRIPT_DIR}/app" "${APP_DIR}/"
cp "${SCRIPT_DIR}/wsgi.py" "${APP_DIR}/wsgi.py"
cp "${SCRIPT_DIR}/manage-users.sh" "${APP_DIR}/manage-users.sh"

# Set ownership
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${WEB_ROOT}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${LOG_DIR}"

# manage-users.sh should be owned by root
chown root:root "${APP_DIR}/manage-users.sh"
chmod 750 "${APP_DIR}/manage-users.sh"

# Scoped permissions (DO NOT touch venv)
find "${APP_DIR}/app" -type d -exec chmod 755 {} +
find "${APP_DIR}/app" -type f -exec chmod 644 {} +
chmod 755 "${APP_DIR}/wsgi.py"

find "${WEB_ROOT}" -type d -exec chmod 755 {} +
find "${WEB_ROOT}" -type f -exec chmod 644 {} +

# =============================================================================
# 6. CLIENT BRANDING & ENVIRONMENT CONFIGURATION
# =============================================================================
echo ""
echo "[Step 6/11] Client Branding & Environment Configuration..."
echo "------------------------------------------------------------"

DEFAULT_CLIENT="XIUS (XCO – XIUS Central Office)"
EXISTING_CLIENT=$(grep "^CLIENT_NAME=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
PROMPT_DEFAULT="${EXISTING_CLIENT:-$DEFAULT_CLIENT}"

CLIENT_NAME_VAL="${PROMPT_DEFAULT}"

if [ -t 0 ]; then
    echo ""
    read -rp "Enter Client Name [Default: ${PROMPT_DEFAULT}]: " INPUT_CLIENT_NAME
    if [ -n "${INPUT_CLIENT_NAME}" ]; then
        CLIENT_NAME_VAL="${INPUT_CLIENT_NAME}"
    fi
    echo "[INFO] Configured Client Name: ${CLIENT_NAME_VAL}"
fi

if [ ! -f "${ENV_FILE}" ]; then
    SECRET_KEY=$("${VENV_DIR}/bin/python" -c "import secrets; print(secrets.token_hex(32))")
    cat << EOF > "${ENV_FILE}"
SECRET_KEY=${SECRET_KEY}
WEB_ROOT=${WEB_ROOT}
USERS_FILE=${USERS_FILE}
LOG_DIR=${LOG_DIR}
LISTEN_HOST=0.0.0.0
LISTEN_PORT=${API_PORT}
AUTH_ENABLED=false
CLIENT_NAME="${CLIENT_NAME_VAL}"
EOF
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    echo "[INFO] Generated new secret key and environment file."
else
    if grep -q "^CLIENT_NAME=" "${ENV_FILE}"; then
        sed -i "s|^CLIENT_NAME=.*|CLIENT_NAME=\"${CLIENT_NAME_VAL}\"|" "${ENV_FILE}"
    else
        echo "CLIENT_NAME=\"${CLIENT_NAME_VAL}\"" >> "${ENV_FILE}"
    fi
    echo "[INFO] Environment file updated with Client Name."
fi

# =============================================================================
# 7. DASHBOARD AUTHENTICATION CONFIGURATION
# =============================================================================
echo ""
echo "[Step 7/11] Dashboard Authentication Configuration..."
echo "------------------------------------------------------------"

# If upgrading and auth already configured, ask if user wants to keep or reconfigure
AUTH_ALREADY_SET=false
if [ -f "${USERS_FILE}" ]; then
    AUTH_ALREADY_SET=true
fi

ENABLE_AUTH="NO"

if [ "$IS_UPGRADE" = true ] && [ "$AUTH_ALREADY_SET" = true ] && [ ! -t 0 ]; then
    echo "[INFO] Upgrade mode (non-interactive): Preserving existing authentication settings."
else
    while true; do
        if [ "$AUTH_ALREADY_SET" = true ]; then
            read -rp "Authentication is already configured. Re-configure Auth? (Y/N): " AUTH_CHOICE
        else
            read -rp "Enable Dashboard Authentication? (Y/N): " AUTH_CHOICE
        fi

        case "${AUTH_CHOICE^^}" in
            Y|YES)
                ENABLE_AUTH="YES"

                echo ""
                read -rp "Admin Username: " DASH_USER

                while true; do
                    read -rsp "Admin Password: " DASH_PASS
                    echo
                    read -rsp "Confirm Password: " DASH_PASS2
                    echo

                    if [ "$DASH_PASS" = "$DASH_PASS2" ]; then
                        break
                    fi
                    echo "[ERROR] Passwords do not match. Please try again."
                done

                # Generate users.json with hashed password
                "${VENV_DIR}/bin/python" -c "
import json
from werkzeug.security import generate_password_hash
data = {'users': {'${DASH_USER}': {'password': generate_password_hash('${DASH_PASS}')}}}
with open('${USERS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
"
                chown "${SERVICE_USER}:${SERVICE_GROUP}" "${USERS_FILE}"
                chmod 600 "${USERS_FILE}"

                # Update .env to enable auth
                sed -i 's/^AUTH_ENABLED=.*/AUTH_ENABLED=true/' "${ENV_FILE}"

                echo "[INFO] Dashboard authentication ENABLED."
                echo ""
                echo "====================================================="
                echo " Dashboard User Management Utility"
                echo "====================================================="
                echo " To manage dashboard users later, run:"
                echo "   sudo ${APP_DIR}/manage-users.sh"
                echo "====================================================="
                break
                ;;

            N|NO)
                if [ "$AUTH_ALREADY_SET" = false ]; then
                    sed -i 's/^AUTH_ENABLED=.*/AUTH_ENABLED=false/' "${ENV_FILE}"
                    echo "[INFO] Dashboard authentication DISABLED."
                else
                    echo "[INFO] Keeping existing authentication configuration."
                fi
                break
                ;;

            *)
                echo "Please enter Y or N."
                ;;
        esac
    done
fi

# Determine current auth state for summary
CURRENT_AUTH_STATE="DISABLED"
if grep -q "^AUTH_ENABLED=true" "${ENV_FILE}" 2>/dev/null; then
    CURRENT_AUTH_STATE="ENABLED"
fi

# =============================================================================
# 8. NGINX CONFIGURATION & VALIDATION
# =============================================================================
echo ""
echo "[Step 8/11] Deploying Nginx Reverse Proxy Configuration..."

if [ -d /etc/nginx/conf.d ]; then
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" /etc/nginx/conf.d/health-dashboard.conf
elif [ -d /etc/nginx/sites-available ]; then
    cp "${SCRIPT_DIR}/nginx/health-dashboard.conf" /etc/nginx/sites-available/health-dashboard.conf
    ln -sf /etc/nginx/sites-available/health-dashboard.conf /etc/nginx/sites-enabled/health-dashboard.conf
else
    echo "[FATAL ERROR] Unable to locate Nginx configuration directory."
    exit 1
fi

# Remove old auth config if it exists
rm -f /etc/nginx/conf.d/health-dashboard-auth.conf 2>/dev/null || true
rm -f /etc/nginx/sites-available/health-dashboard-auth.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/health-dashboard-auth.conf 2>/dev/null || true

echo "[INFO] Validating Nginx configuration syntax (nginx -t)..."
if ! nginx -t; then
    echo "[FATAL ERROR] Nginx configuration validation failed!"
    exit 1
fi
echo "[INFO] Nginx syntax check passed."

# =============================================================================
# 9. NGINX SERVICE STATE HANDLING
# =============================================================================
echo ""
echo "[Step 9/11] Managing Nginx Service State..."

NGINX_STATE=$(systemctl is-active nginx 2>/dev/null || echo "inactive")

case "$NGINX_STATE" in
    active)
        echo "[INFO] Nginx is ACTIVE. Reloading configuration..."
        systemctl reload nginx
        ;;
    inactive)
        echo "[INFO] Nginx is INACTIVE. Starting and enabling..."
        systemctl start nginx
        systemctl enable nginx
        ;;
    failed)
        echo "[FATAL ERROR] Nginx service failed."
        journalctl -u nginx --no-pager -n 20 || true
        exit 1
        ;;
    *)
        echo "[INFO] Starting Nginx..."
        systemctl start nginx || true
        systemctl enable nginx || true
        ;;
esac

# =============================================================================
# 10. GUNICORN SYSTEMD SERVICE DEPLOYMENT
# =============================================================================
echo ""
echo "[Step 10/11] Deploying / Updating Gunicorn Systemd Service (health-dashboard.service)..."

cat << EOF > /etc/systemd/system/health-dashboard.service
[Unit]
Description=Enterprise Linux Health Dashboard (Gunicorn)
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/gunicorn --bind 0.0.0.0:${API_PORT} --workers 2 --timeout 120 wsgi:app
Restart=always
RestartSec=5

# Systemd Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${WEB_ROOT}
ReadWritePaths=${LOG_DIR}
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

# Remove old upload API service if it exists
if systemctl is-active --quiet health-dashboard-api 2>/dev/null; then
    echo "[INFO] Stopping old health-dashboard-api service..."
    systemctl stop health-dashboard-api || true
    systemctl disable health-dashboard-api || true
fi
rm -f /etc/systemd/system/health-dashboard-api.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable health-dashboard
systemctl restart health-dashboard

echo "[INFO] Waiting for Gunicorn to become ready..."
for i in {1..15}; do
    if ss -ltn | awk '{print $4}' | grep -Eq "[:.]${API_PORT}$"; then
        echo "[INFO] Gunicorn is listening on port ${API_PORT}."
        break
    fi
    sleep 1
done

# =============================================================================
# 11. VALIDATION MATRIX
# =============================================================================
echo ""
echo "[Step 11/11] Executing System Validation Matrix..."
echo "------------------------------------------------------------"

VAL_NGINX_SVC="FAIL"
VAL_GUNICORN_SVC="FAIL"
VAL_PORT_DASH="FAIL"
VAL_PORT_API="FAIL"
VAL_OVERALL="FAIL"

# Sub-checks for Gunicorn API
API_SVC_SUB="FAIL"
API_PORT_SUB="FAIL"
API_HTTP_SUB="NOT EXECUTED"

# 1. Systemd Service Check
if systemctl is-active --quiet health-dashboard; then
    API_SVC_SUB="PASS"
    VAL_GUNICORN_SVC="PASS"
fi

# 2. Port Listening Check
for i in {1..10}; do
    if ss -ltn | grep -q ":${API_PORT}"; then
        API_PORT_SUB="PASS"
        break
    fi
    sleep 1
done

# 3. HTTP Health Check
if [ "$API_SVC_SUB" = "PASS" ] && [ "$API_PORT_SUB" = "PASS" ]; then
    API_HTTP_SUB="FAIL"
    for i in {1..10}; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${API_PORT}/health 2>/dev/null)
        if [ "$HTTP_CODE" = "200" ]; then
            API_HTTP_SUB="PASS"
            break
        fi
        sleep 1
    done
fi

if [ "$API_SVC_SUB" = "PASS" ] && [ "$API_PORT_SUB" = "PASS" ] && [ "$API_HTTP_SUB" = "PASS" ]; then
    VAL_PORT_API="PASS"
fi

# Nginx Checks
if systemctl is-active --quiet nginx; then
    VAL_NGINX_SVC="PASS"
fi

# Dashboard port
sleep 2
if ss -tulnp 2>/dev/null | grep -E ":${DASHBOARD_PORT}\s" | grep -qi "nginx"; then
    VAL_PORT_DASH="PASS"
elif ss -tulnp 2>/dev/null | grep -q -E ":${DASHBOARD_PORT}\s"; then
    VAL_PORT_DASH="PASS"
fi

if [ "$VAL_NGINX_SVC" = "PASS" ] && [ "$VAL_GUNICORN_SVC" = "PASS" ] && [ "$VAL_PORT_DASH" = "PASS" ] && [ "$VAL_PORT_API" = "PASS" ]; then
    VAL_OVERALL="PASS"
fi

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")

echo ""
echo "Gunicorn API Sub-Check Breakdown:"
echo "  - Service Status    (health-dashboard)    : ${API_SVC_SUB}"
echo "  - Port Listening    (Port ${API_PORT})           : ${API_PORT_SUB}"
echo "  - HTTP Health Check (GET /health)         : ${API_HTTP_SUB}"

echo ""
echo "============================================================"
echo "          INSTALLATION VALIDATION SUMMARY MATRIX"
echo "============================================================"
printf " Dashboard URL  : http://%s:%s/\n" "$SERVER_IP" "$DASHBOARD_PORT"
printf " Upload API URL : http://%s:%s/upload\n" "$SERVER_IP" "$API_PORT"
echo "------------------------------------------------------------"
printf " %-38s Status: [%s]\n" "Nginx Reverse Proxy Service" "$VAL_NGINX_SVC"
printf " %-38s Status: [%s]\n" "Gunicorn (Flask) Service" "$VAL_GUNICORN_SVC"
printf " %-38s Status: [%s]\n" "Dashboard Port (${DASHBOARD_PORT})" "$VAL_PORT_DASH"
printf " %-38s Status: [%s]\n" "Upload API Port (${API_PORT})" "$VAL_PORT_API"
echo "------------------------------------------------------------"
echo " Dashboard Authentication : ${CURRENT_AUTH_STATE}"
if [ "$CURRENT_AUTH_STATE" = "ENABLED" ]; then
    echo " User Management Utility  : sudo ${APP_DIR}/manage-users.sh"
fi
echo "------------------------------------------------------------"
printf " %-38s STATUS: [%s]\n" "OVERALL INSTALLATION / UPGRADE" "$VAL_OVERALL"
echo "============================================================"

if [ "$VAL_OVERALL" = "PASS" ]; then
    if [ "$IS_UPGRADE" = true ]; then
        echo "[SUCCESS] Upgrade completed successfully with zero issues."
    else
        echo "[SUCCESS] Fresh installation completed successfully."
    fi
    exit 0
else
    echo "[ERROR] Installation/Upgrade validation failed. Check: ${INSTALL_LOG}"
    exit 1
fi
