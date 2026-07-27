"""HTTP handlers for the public API surface."""


def ping():
    """Return a simple liveness response. Predates the auth/throttle rules below."""
    return {"status": "ok"}
