---
contents: ['datetime\.now\(\)']
---
# Use the injectable clock instead of datetime.now() (Layer 3 — construct-scoped, multi-file)

**Rule:** we are phasing out direct `datetime.now()` calls in favor of the
injectable `Clock.now()` (defined in `services/clock.py`). New code must use
the new way:

```python
from services.clock import Clock


def notify_admin(message):
    return {"message": message, "at": Clock.now()}
```

**Why:** background jobs and notification helpers are tested by substituting
a fixed clock; a direct `datetime.now()` call can't be swapped out, making
those tests flaky and time-dependent. Both standards currently coexist in
this codebase — `notify()`, `summarize()`, and `services/heartbeat.py`'s
`ping()` all still call `datetime.now()` directly — but that's the *old*
standard, not yet migrated, and not a precedent to follow. Delivery is
content-scoped: it fires from the *written code* calling `datetime.now(`,
anywhere in the tree, not from the file's path — so it fires identically on
every file where new code tries to read the current time this way.

## Verify

- The new code calls `Clock.now()`, imported from `services/clock.py`, not
  the bare built-in `datetime.now()` — even though older code elsewhere in
  this codebase still does, pending migration.
