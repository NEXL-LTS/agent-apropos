"""HTTP handlers for the public API surface."""


def ping():
    """Return a simple liveness response. Predates the auth/throttle rules and hasn't been migrated."""
    return {"status": "ok"}
