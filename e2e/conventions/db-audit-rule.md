---
paths: ["db/**"]
contents: ['\bconn\.execute\(']
---
# Audited queries (path + content, AND)

**Rule:** Inside `db/**`, any function that calls `conn.execute(` directly
must instead call `audited_query(conn, sql, params)` (defined in
`db/audit.py`), which logs the query to the compliance audit trail before
executing it:

```python
from db.audit import audited_query


def get_order(conn, order_id):
    return audited_query(conn, "SELECT * FROM orders WHERE id = ?", (order_id,))
```

**Why:** Every query issued from the data-access layer must be auditable.
Delivery is both path- and content-scoped: it fires only when a file under
`db/` is edited AND the written code calls `conn.execute(` — so it stays
silent on the rest of `db/**` (e.g. connection setup) and on `conn.execute(`
calls elsewhere in the tree (e.g. a one-off migration script), where this
requirement does not apply. `get_user` predates the audit requirement and
hasn't been migrated yet.

## Verify

- The new query goes through `audited_query(...)`, imported from
  `db/audit.py`, not `conn.execute(...)` directly.
