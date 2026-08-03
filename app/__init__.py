"""
Enterprise Linux Health Dashboard - Flask Application Factory
"""

import os
import sys
import logging
from datetime import timedelta
from functools import wraps

from flask import Flask, session, redirect, url_for, request

from app.config import Config


def create_app():
    """Create and configure the Flask application."""
    app = Flask(__name__)
    app.config.from_object(Config)
    app.permanent_session_lifetime = timedelta(seconds=Config.PERMANENT_SESSION_LIFETIME)

    # -------------------------------------------------------------------------
    # Logging
    # -------------------------------------------------------------------------
    log_dir = Config.LOG_DIR
    os.makedirs(log_dir, exist_ok=True)

    handlers = [logging.StreamHandler(sys.stdout)]
    log_file = os.path.join(log_dir, "app.log")
    try:
        handlers.append(logging.FileHandler(log_file, mode="a"))
    except Exception:
        pass

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=handlers,
    )

    # -------------------------------------------------------------------------
    # Register Blueprints
    # -------------------------------------------------------------------------
    from app.auth import auth_bp
    from app.dashboard import dashboard_bp
    from app.report import report_bp
    from app.compare import compare_bp
    from app.upload_api import upload_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(report_bp)
    app.register_blueprint(compare_bp)
    app.register_blueprint(upload_bp)

    # -------------------------------------------------------------------------
    # Before-request: session timeout & auth check
    # -------------------------------------------------------------------------
    PUBLIC_PREFIXES = ("/upload", "/health", "/static", "/login", "/reports/")

    @app.before_request
    def check_auth():
        # Skip auth check for public endpoints
        for prefix in PUBLIC_PREFIXES:
            if request.path.startswith(prefix):
                return None

        if not Config.AUTH_ENABLED:
            return None

        # Check if user is logged in
        if "user" not in session:
            return redirect(url_for("auth.login"))

        # Check session timeout (non-permanent sessions)
        import time
        login_time = session.get("login_time", 0)
        if not session.get("remember_me") and (time.time() - login_time) > Config.SESSION_TIMEOUT:
            session.clear()
            return redirect(url_for("auth.login", timeout="1"))

    # Context Processor: Inject global template variables
    @app.context_processor
    def inject_globals():
        return {
            "client_name": Config.CLIENT_NAME,
            "auth_enabled": Config.AUTH_ENABLED,
        }

    # -------------------------------------------------------------------------
    # Error handlers
    # -------------------------------------------------------------------------
    @app.errorhandler(404)
    def not_found(error):
        from flask import render_template
        return render_template("layout.html", content="<h2>Page Not Found</h2>"), 404

    @app.errorhandler(500)
    def internal_error(error):
        logging.getLogger(__name__).error("Internal server error: %s", error)
        from flask import render_template
        return render_template("layout.html", content="<h2>Internal Server Error</h2>"), 500

    return app


def login_required(f):
    """Decorator to require login for a view function."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if Config.AUTH_ENABLED and "user" not in session:
            return redirect(url_for("auth.login"))
        return f(*args, **kwargs)
    return decorated_function
