---
contents: ['\bNotImplementedError\b']
---
# Deferred stubs use StubNotImplemented (content-scoped)

**Rule:** Do not raise the bare built-in `NotImplementedError` for a
deliberately deferred stub. Raise `StubNotImplemented("<feature>")` instead
(defined in `scripts/errors.py`):

```python
from scripts.errors import StubNotImplemented


def sync():
    raise StubNotImplemented("sync")
```

**Why:** Our stub-tracking tool greps for `NotImplementedError` to flag
missing implementations as bugs. A deliberately deferred stub needs to be
distinguishable from a genuine one, so it raises our own subclass instead.
Delivery is content-scoped: it fires from the *written code* matching
`NotImplementedError`, anywhere in the tree, not from the file's path.

## Verify

- The stub raises `StubNotImplemented(...)`, imported from
  `scripts/errors.py`, not the bare built-in.
