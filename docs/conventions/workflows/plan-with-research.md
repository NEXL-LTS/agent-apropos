---
skill: true
description: "Use when planning a new feature or change with the user — from the first proposal through the rest of the planning discussion — to ground the plan in how the code actually behaves today instead of assumptions or memory."
---

# Planning against the real code, not memory

**Rule:** When planning a feature with the user, don't propose an approach
from memory or a guess at how something "probably" works. Before proposing
anything, go read the current related code — the module, endpoint, or flow
the feature will touch — and base the plan on what it actually does. As the
planning conversation continues and new questions or constraints come up,
keep re-checking the code rather than reasoning from what was read earlier or
assumed; behavior uncovered mid-conversation can invalidate an earlier
assumption. Ask the user clarifying questions whenever a requirement,
edge case, or intended behavior isn't settled by the code or the request —
don't fill the gap with a guess.

**Why:** A plan built on a remembered or assumed version of the codebase
produces a design for code that doesn't exist, and the mismatch surfaces only
after implementation starts, costing a rework cycle. Verifying continuously
rather than once up front matters because planning discussions shift scope —
a clarifying answer or a new constraint can point at a different part of the
system than the one first investigated.

**Watch out:** Don't let one round of research at the start substitute for
verification throughout. If the user proposes a variant mid-discussion, or a
new file/behavior comes up, check it before reasoning about it, not after the
plan is written.

## Verify

- The plan cites or reflects specific current-code behavior (files, functions,
  flows) rather than general or remembered claims about the system.
- Behavior claims introduced later in the planning discussion are checked
  against the code before being relied on.
- Unsettled requirements or edge cases were resolved by asking the user, not
  by assumption.
