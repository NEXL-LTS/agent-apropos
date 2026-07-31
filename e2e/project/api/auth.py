"""Authentication for the public API surface."""

import functools


def require_auth(fn):
    """Wrap fn so it only runs for an authenticated caller (no-op placeholder for now)."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        return fn(*args, **kwargs)

    return wrapper
