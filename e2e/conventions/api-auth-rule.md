---
paths: ["api/**"]
---
# Authenticate every handler (Layer 2 — path-scoped)

**Rule:** `api/` is the public HTTP surface. Every new handler function
added under `api/` must be wrapped in the `require_auth` decorator
(imported from `api/auth.py`):

```python
from api.auth import require_auth


@require_auth
def new_handler(...):
    ...
```

**Why:** every request reaching a handler must be authenticated first;
`ping()` predates this requirement and hasn't been migrated. Delivery is
path-scoped, so it arrives whenever a file under `api/` is edited,
regardless of what the new handler does. See `api-throttle-rule.md` for the
second `api/**` rule that also applies here, and the stacking order the two
require together.

## Verify

- The new handler is wrapped in `require_auth`, imported from `api/auth.py`.
