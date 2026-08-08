---
skill: true
description: "Use when adding a new arithmetic operation to the calc library"
---
# Adding an arithmetic operation (Layer 3 — intent skill)

When adding a new operation to the calc library at `lib/calc.py`, don't just
define a bare function — register it in the dispatch table so it's callable
by name:

```python
from lib.registry import register_operation


def divide(a, b):
    """Return a divided by b."""
    return a / b


register_operation("divide", divide)
```

Keep the function itself pure — operands in, result out, no I/O — with a
one-line docstring.

**Why:** This guidance is triggered by the *intent* of the task ("add an
arithmetic operation"), not by a path or a code construct, so it is delivered
as a skill. `add`/`multiply` predate the registry and haven't been migrated;
new operations must register going forward so the calculator can dispatch by
name.

## Verify

- The new operation is a pure function with a docstring, and is registered
  via `register_operation("<name>", <fn>)` imported from `lib/registry.py`.
