# Enterprise Linux Health Dashboard

Production-ready enterprise Linux server health monitoring and reporting system designed for air-gapped private network environments.

## Clean Project Structure

```
linux-health-dashboard/
├── health_check.sh             # SINGLE standalone script for all Linux client servers
├── install.sh                  # One-click installer script for the central server
├── README.md                   # System documentation
├── upload/
│   ├── upload.py               # Flask Upload API (Port 5000)
│   └── generate_dashboard.py   # Automatic static dashboard generator
├── templates/
│   ├── header.html             # Standalone report header template
│   ├── footer.html             # Standalone report footer template
│   ├── style.css               # Custom stylesheet
│   └── dashboard.html          # Central dashboard layout template
├── nginx/
│   └── health-dashboard.conf   # Nginx configuration (Port 8088)
└── reports/
    └── .gitkeep
```

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

## Supported Operating Systems
- RHEL 6 / 7 / 8 / 9 / 10
- Ubuntu 18.04 / 20.04 / 22.04 / 24.04

## Quick Start Guide

### 1. Central Server Setup
On the monitoring server:
```bash
git clone <repo-url> linux-health-dashboard
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
0 6 * * * /path/to/health_check.sh > /dev/null 2>&1
```
