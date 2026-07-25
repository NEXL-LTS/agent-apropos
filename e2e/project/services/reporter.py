"""Reporting helpers."""

from datetime import datetime


def summarize(message):
    """Return a formatted summary with a timestamp. Predates the Clock migration below."""
    return f"[summary] {message} at {datetime.now()}"
