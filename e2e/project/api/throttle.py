"""Rate limiting for the public API surface."""

import functools


def rate_limited(fn):
    """Wrap fn so repeated calls are throttled (no-op placeholder for now)."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        return fn(*args, **kwargs)

    return wrapper
