# Enterprise Linux Health Dashboard

Production-ready enterprise Linux server health monitoring and reporting system designed for air-gapped private network environments and production gateway servers (e.g. OpsRamp Gateway, RHEL, Ubuntu).

## Architecture

```
Production Linux Servers (RHEL 6-10, Ubuntu 18-24)
        │
        ▼
   health_check.sh (Single standalone script on client nodes)
        │
        ├──► HealthCheck_hostname_date.txt
        └──► HealthCheck_hostname_date.html
                │
                ▼ (curl POST upload)
        Flask Upload API (:5000/upload)
            └─► Running in Venv (/opt/health-dashboard/venv)
            └─► Executed by unprivileged user (healthdashboard)
                │
                ▼
        Store in /var/www/html/health-reports/<hostname>/
                │
                ▼
        generate_dashboard.py (Auto rebuild index.html)
                │
                ▼
        Nginx Web Server (:8088)
```

## Production & Security Specifications

1. **Python Virtual Environment**:
   - Flask API runs exclusively inside `/opt/health-dashboard/venv` (no global pip modifications).
2. **Dedicated Unprivileged Service Account**:
   - Runs under dedicated system account `healthdashboard:healthdashboard` (never root).
3. **Zero Production Traffic Disruption**:
   - Uses `nginx -t && systemctl reload nginx` (never restarts Nginx).
   - Only installs missing packages without reinstalling existing ones.
4. **Strict Pre-Installation Port Checks**:
   - Immediately aborts installation if port `5000` or `8088` is occupied to prevent service conflicts.
5. **Systemd Security Hardening**:
   - Enforces `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=full`, and `ProtectHome=true`.
6. **Strict Permissions**:
   - `755` for directories, `644` for files, owned by `healthdashboard`. No `777` permissions.
7. **Validation Matrix**:
   - Post-install automated health check matrix verifying venv, service states, and HTTP endpoints with explicit `[PASS]` / `[FAIL]` status.

## Supported Operating Systems
- RHEL 6 / 7 / 8 / 9 / 10
- Ubuntu 18.04 / 20.04 / 22.04 / 24.04

## Quick Start Guide

### 1. Central Monitoring Server Installation
On the central server:
```bash
git clone https://github.com/Prathaps8675/linux-checklist.git linux-health-dashboard
cd linux-health-dashboard
chmod +x install.sh
sudo ./install.sh
```

### 2. Client Node Setup (Only 1 Script Needed!)
On any production Linux server:
1. Copy **only** `health_check.sh`.
2. Edit `REPORT_SERVER` at the top of `health_check.sh`:
   ```bash
   REPORT_SERVER="10.0.27.53"
   REPORT_PORT="5000"
   ```
3. Run the health check:
   ```bash
   chmod +x health_check.sh
   sudo ./health_check.sh
   ```

### Daily Cron Job Example
```bash
0 6 * * * /opt/health-reports/health_check.sh > /dev/null 2>&1
```
