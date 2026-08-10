---
paths: ["src/**"]
---
# Tracing on the public surface (path-scoped)

**Rule:** `src/` is this project's public surface. Every new function added
under `src/` must be wrapped in the `@trace_call` decorator (imported from
`src/telemetry.py`), placed directly above the `def` line:

```python
from src.telemetry import trace_call


@trace_call
def new_function(...):
    ...
```

**Why:** All public entry points emit tracing spans so calls show up in the
dashboard. `shout()` predates this requirement and hasn't been migrated —
new code must comply going forward. Delivery is path-scoped, so it arrives
whenever a file under `src/` is edited, regardless of what the new code does.

## Verify

- The new function is preceded by `@trace_call`, and the file imports it from
  `src/telemetry.py`.
