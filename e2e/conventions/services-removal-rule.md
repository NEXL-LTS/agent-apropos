---
paths: ["services/**"]
on: [removed]
---
# Record removed services (removal-scoped)

**Rule:** `services/` modules back production heartbeats and alerts. Whenever
a file under `services/` is deleted, add a line to `services/DECOMMISSIONED.md`
recording it, in the form:

```
Decommissioned: <filename>
```

**Why:** ops has monitors configured against each module by name; without a
record here, a removed service's alerts keep firing against a file that no
longer exists instead of being retired alongside it. Delivery is
removal-scoped, so it fires when a tracked file under `services/**` is
deleted — not on an ordinary edit to one.

## Verify

- `services/DECOMMISSIONED.md` contains a `Decommissioned: <filename>` line
  naming the file that was removed.
