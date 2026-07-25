"""Notification helpers."""

from datetime import datetime


def notify(message):
    """Return a formatted notice with a timestamp. Predates the Clock migration below."""
    return f"[notice] {message} at {datetime.now()}"
