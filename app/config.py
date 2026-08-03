"""Configuration module for the Enterprise Linux Health Dashboard."""

import os
import secrets


class Config:
    """Application configuration loaded from environment variables with sensible defaults."""

    # Flask core
    SECRET_KEY = os.environ.get("SECRET_KEY", secrets.token_hex(32))
    MAX_CONTENT_LENGTH = 50 * 1024 * 1024  # 50 MB

    # Paths
    WEB_ROOT = os.environ.get("WEB_ROOT", "/var/www/html/health-reports")
    USERS_FILE = os.environ.get("USERS_FILE", "/opt/health-dashboard/users.json")
    LOG_DIR = os.environ.get("LOG_DIR", "/var/log/health-dashboard")

    # Session
    SESSION_TIMEOUT = int(os.environ.get("SESSION_TIMEOUT", "1800"))  # 30 minutes
    PERMANENT_SESSION_LIFETIME = 86400 * 30  # 30 days for "Remember Me"

    # Authentication
    AUTH_ENABLED = os.environ.get("AUTH_ENABLED", "false").lower() in ("true", "1", "yes")

    # Server
    LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "5000"))
