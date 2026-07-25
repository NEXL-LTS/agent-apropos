"""Liveness heartbeat pings. Predates the Clock migration below."""

from datetime import datetime


def ping():
    """Return the current time as a plain heartbeat timestamp."""
    return datetime.now()
