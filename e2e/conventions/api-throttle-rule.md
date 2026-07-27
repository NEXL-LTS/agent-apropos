---
paths: ["api/**"]
---
# Throttle every handler, outermost (Layer 2 — path-scoped)

**Rule:** Every new handler function added under `api/` must also be
wrapped in `rate_limited` (imported from `api/throttle.py`) — and it must be
the *outermost* decorator, listed above `require_auth`, not below it:

```python
from api.auth import require_auth
from api.throttle import rate_limited


@rate_limited
@require_auth
def new_handler(...):
    ...
```

**Why:** counter-intuitively, throttling must run *before* authentication,
not after. Decorators apply bottom-up, so whichever one must see the
request first at call time is listed first, above the others: an
unauthenticated flood should be rejected by the (cheap) rate limiter before
it ever reaches the (comparatively expensive) auth check — reversing the
order would let exactly the traffic this rule exists to stop burn auth
capacity instead. `ping()` predates both requirements and hasn't been
migrated.

## Verify

- The new handler is wrapped in both `rate_limited` (from
  `api/throttle.py`) and `require_auth` (from `api/auth.py`), with
  `rate_limited` listed above `require_auth`.
