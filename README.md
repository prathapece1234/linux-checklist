# Enterprise Linux Health Dashboard

Dynamic enterprise Linux server health monitoring, reporting, and report comparison system built with **Flask**, **Gunicorn**, and **Nginx Reverse Proxy**.

Designed for production Linux environments (OpsRamp Gateway, RHEL 6–10, Ubuntu 18–24, Amazon Linux).

## Architecture

```
Production Client Nodes (RHEL 6-10, Ubuntu, Amazon Linux)
        │
        ▼
   health_check.sh (Single standalone script on client nodes)
        │
        ├──► HealthCheck_hostname_date.txt
        ├──► HealthCheck_hostname_date.html
        └──► HealthCheck_hostname_date.json
                │
                ▼ (curl POST upload)
        Upload API (/upload - Unauthenticated)
                │
                ▼
        Store in /var/www/html/health-reports/<hostname>/
                │
                ▼
   Dynamic Flask Web Application (Gunicorn :5000) ◄── Nginx Reverse Proxy (:8088)
        ├── Session-Based Authentication (login/logout)
        ├── Dynamic Server Cards Dashboard
        ├── Report Viewer & History
        └── Before vs After Activity Report Comparison (JSON diff)
```

## Features

- **Dynamic Flask Web App**: Zero static HTML generator overhead. Dashboard renders dynamically on demand.
- **Session Authentication**: Flask session management with `werkzeug.security` hashed passwords (`users.json`). 30-minute timeout & "Remember Me" support.
- **Report Comparison Engine**: Select any two reports (Before vs After activity) for a server and instantly compare System, Storage (filesystems & mount points), Memory (RAM & Swap), Services, Network (IPs & `route -n` routes), and Security (SELinux & NTP) with color-coded PASS/WARNING/FAIL/INFO indicators.
- **User Management Utility**: `manage-users.sh` interactive CLI tool to list, add, delete users, and change passwords.
- **Gunicorn Production Deployment**: Runs behind Nginx reverse proxy with systemd security hardening (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`).
- **Backward Compatible**: Existing client agents (`health_check.sh`) continue uploading without authentication or breaking changes.

## Supported Operating Systems
- RHEL 6 / 7 / 8 / 9 / 10
- Ubuntu 18.04 / 20.04 / 22.04 / 24.04
- Amazon Linux

## Quick Start Guide

### 1. Central Server Installation
On the central monitoring server:
```bash
git clone https://github.com/Prathaps8675/linux-checklist.git linux-health-dashboard
cd linux-health-dashboard
chmod +x install.sh
sudo ./install.sh
```

### 2. User Management CLI
To manage dashboard users (add, delete, change passwords):
```bash
sudo /opt/health-dashboard/manage-users.sh
```

### 3. Client Node Setup (Only 1 Script Needed!)
On any production Linux node:
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
