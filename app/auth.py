"""
Authentication blueprint — Login, Logout, Session Management.
Uses werkzeug password hashing with users.json file storage.
"""

import os
import json
import time
import logging

from flask import Blueprint, render_template, request, redirect, url_for, session, flash
from werkzeug.security import check_password_hash

from app.config import Config

auth_bp = Blueprint("auth", __name__)
logger = logging.getLogger(__name__)


def load_users():
    """Load users from the users.json file."""
    users_file = Config.USERS_FILE
    if not os.path.isfile(users_file):
        return {}
    try:
        with open(users_file, "r") as f:
            data = json.load(f)
        return data.get("users", {})
    except Exception as e:
        logger.error("Failed to load users file %s: %s", users_file, e)
        return {}


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    """Handle login page and authentication."""
    # If auth is disabled, redirect to dashboard
    if not Config.AUTH_ENABLED:
        return redirect(url_for("dashboard.index"))

    # If already logged in, redirect to dashboard
    if "user" in session:
        return redirect(url_for("dashboard.index"))

    error = None
    timeout = request.args.get("timeout")

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        remember = request.form.get("remember_me") == "on"

        users = load_users()

        if username in users and check_password_hash(users[username]["password"], password):
            session["user"] = username
            session["login_time"] = time.time()
            session["remember_me"] = remember

            if remember:
                session.permanent = True
            else:
                session.permanent = False

            logger.info("User '%s' logged in from %s", username, request.remote_addr)
            return redirect(url_for("dashboard.index"))
        else:
            error = "Invalid username or password."
            logger.warning("Failed login attempt for user '%s' from %s", username, request.remote_addr)

    return render_template("login.html", error=error, timeout=timeout)


@auth_bp.route("/logout")
def logout():
    """Destroy session and redirect to login."""
    username = session.get("user", "unknown")
    session.clear()
    logger.info("User '%s' logged out.", username)
    return redirect(url_for("auth.login"))
