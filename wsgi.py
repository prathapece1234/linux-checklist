#!/usr/bin/env python3
"""Gunicorn WSGI entry point for the Enterprise Linux Health Dashboard."""

from app import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
