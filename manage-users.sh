#!/bin/bash
# =============================================================================
# Enterprise Linux Health Dashboard - User Management Utility
# =============================================================================
# Manages users.json for Flask session-based authentication.
# Passwords are always hashed using werkzeug.security.
#
# Usage: sudo /opt/health-dashboard/manage-users.sh
# =============================================================================

set -e

USERS_FILE="${USERS_FILE:-/opt/health-dashboard/users.json}"
VENV_DIR="${VENV_DIR:-/opt/health-dashboard/venv}"
PYTHON="${VENV_DIR}/bin/python"

# Ensure root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This utility must be run as root."
    exit 1
fi

# Ensure venv python exists
if [ ! -x "$PYTHON" ]; then
    echo "[ERROR] Python venv not found at $PYTHON."
    echo "        Run install.sh first."
    exit 1
fi

# Initialize users.json if it doesn't exist
if [ ! -f "$USERS_FILE" ]; then
    echo '{"users":{}}' > "$USERS_FILE"
    chmod 600 "$USERS_FILE"
fi

# Helper: hash a password using Python werkzeug
hash_password() {
    local password="$1"
    "$PYTHON" -c "
from werkzeug.security import generate_password_hash
print(generate_password_hash('${password}'))
"
}

# Helper: load users JSON
load_users() {
    cat "$USERS_FILE" 2>/dev/null || echo '{"users":{}}'
}

# Helper: save users JSON
save_users() {
    local data="$1"
    echo "$data" > "$USERS_FILE"
    chmod 600 "$USERS_FILE"
}

# 1. List Users
list_users() {
    echo ""
    echo "Registered Users:"
    echo "-------------------------------------------"
    "$PYTHON" -c "
import json
with open('${USERS_FILE}', 'r') as f:
    data = json.load(f)
users = data.get('users', {})
if not users:
    print('  (No users configured)')
else:
    for i, username in enumerate(sorted(users.keys()), 1):
        print(f'  {i}. {username}')
print(f'\nTotal: {len(users)} user(s)')
"
    echo ""
}

# 2. Add User
add_user() {
    echo ""
    read -rp "New Username: " NEW_USER

    if [ -z "$NEW_USER" ]; then
        echo "[ERROR] Username cannot be empty."
        return
    fi

    # Check if user exists
    EXISTS=$("$PYTHON" -c "
import json
with open('${USERS_FILE}', 'r') as f:
    data = json.load(f)
print('yes' if '${NEW_USER}' in data.get('users', {}) else 'no')
")

    if [ "$EXISTS" = "yes" ]; then
        echo "[ERROR] User '${NEW_USER}' already exists."
        return
    fi

    while true; do
        read -rsp "Password: " NEW_PASS
        echo
        read -rsp "Confirm Password: " NEW_PASS2
        echo

        if [ "$NEW_PASS" = "$NEW_PASS2" ]; then
            break
        fi
        echo "[ERROR] Passwords do not match. Try again."
    done

    "$PYTHON" -c "
import json
from werkzeug.security import generate_password_hash
with open('${USERS_FILE}', 'r') as f:
    data = json.load(f)
data.setdefault('users', {})
data['users']['${NEW_USER}'] = {'password': generate_password_hash('${NEW_PASS}')}
with open('${USERS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
"
    chmod 600 "$USERS_FILE"
    echo "[INFO] User '${NEW_USER}' added successfully."
}

# 3. Delete User
delete_user() {
    echo ""
    list_users
    read -rp "Username to delete: " DEL_USER

    if [ -z "$DEL_USER" ]; then
        echo "[ERROR] Username cannot be empty."
        return
    fi

    "$PYTHON" -c "
import json, sys
with open('${USERS_FILE}', 'r') as f:
    data = json.load(f)
if '${DEL_USER}' not in data.get('users', {}):
    print('[ERROR] User not found.')
    sys.exit(1)
del data['users']['${DEL_USER}']
with open('${USERS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
print('[INFO] User deleted successfully.')
"
    chmod 600 "$USERS_FILE"
}

# 4. Change Password
change_password() {
    echo ""
    list_users
    read -rp "Username: " CHG_USER

    if [ -z "$CHG_USER" ]; then
        echo "[ERROR] Username cannot be empty."
        return
    fi

    while true; do
        read -rsp "New Password: " CHG_PASS
        echo
        read -rsp "Confirm Password: " CHG_PASS2
        echo

        if [ "$CHG_PASS" = "$CHG_PASS2" ]; then
            break
        fi
        echo "[ERROR] Passwords do not match. Try again."
    done

    "$PYTHON" -c "
import json, sys
from werkzeug.security import generate_password_hash
with open('${USERS_FILE}', 'r') as f:
    data = json.load(f)
if '${CHG_USER}' not in data.get('users', {}):
    print('[ERROR] User not found.')
    sys.exit(1)
data['users']['${CHG_USER}']['password'] = generate_password_hash('${CHG_PASS}')
with open('${USERS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
print('[INFO] Password changed successfully.')
"
    chmod 600 "$USERS_FILE"
}

# 5. Reset Admin Password
reset_admin() {
    echo ""
    echo "Resetting admin password..."

    while true; do
        read -rsp "New Admin Password: " ADMIN_PASS
        echo
        read -rsp "Confirm Password: " ADMIN_PASS2
        echo

        if [ "$ADMIN_PASS" = "$ADMIN_PASS2" ]; then
            break
        fi
        echo "[ERROR] Passwords do not match. Try again."
    done

    "$PYTHON" -c "
import json
from werkzeug.security import generate_password_hash
with open('${USERS_FILE}', 'r') as f:
    data = json.load(f)
data.setdefault('users', {})
data['users']['admin'] = {'password': generate_password_hash('${ADMIN_PASS}')}
with open('${USERS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
print('[INFO] Admin password reset successfully.')
"
    chmod 600 "$USERS_FILE"
}

# Menu
while true; do
    echo ""
    echo "============================================"
    echo " Health Dashboard - User Management"
    echo "============================================"
    echo "  1) List Users"
    echo "  2) Add User"
    echo "  3) Delete User"
    echo "  4) Change Password"
    echo "  5) Reset Admin Password"
    echo "  6) Exit"
    echo "============================================"
    read -rp "Select option [1-6]: " CHOICE

    case "$CHOICE" in
        1) list_users ;;
        2) add_user ;;
        3) delete_user ;;
        4) change_password ;;
        5) reset_admin ;;
        6) echo "Goodbye."; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
