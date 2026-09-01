---
paths: ["tool/mutate/ignore.json"]
---
# An ignore entry needs equivalence, not just "unobservable"

**Rule:** Before adding an entry here, ask *why* the mutation is
unobservable — two different reasons look identical from the mutant's
outcome but demand different fixes. If two implementations are both
legitimately valid (git accepts `--verify` before or after the ref on
`rev-parse`), the code is fine as-is and the ignore entry is the right call.
If instead the mutation proves a guard, branch, or line can never affect the
result *because it can never be reached* given the surrounding logic — not
two paths agreeing, but one of them being provably dead — that's dead code.
Delete it instead; matching the same pattern elsewhere in the codebase is
not a reason to keep it.

**Why:** An ignore entry for dead code documents the debt instead of paying
it — it makes the mutation gate quiet about a branch that was never doing
anything, forever. `agents/copilot.cr`'s `upgrade_bash_target` had a guard
checking a short prefix before checking two longer prefixes that already
imply it; the guard could never reject anything the following `if`/`elsif`
didn't already reject on its own. The fix was deleting the guard, not
adding a reviewed "this can't be observed" entry for it.

**Watch out:** The two failure modes pull in opposite directions. Reaching
for an ignore entry before checking reachability freezes dead code into the
codebase behind a paper trail that makes it look reviewed rather than
removed. Reaching for a code change when the mutation genuinely is
equivalent-but-not-dead (the git flag-order entries) means chasing an
assertion that can never exist.

## Verify

- Every new entry's reason argues two implementations are both valid — never
  that a branch is unreachable. An unreachable branch is deleted, named in
  the commit body, with no ignore entry at all.
- `occurrence` is the 1-based index of `original` among identically-trimmed
  lines in the file (see `docs/mutation-testing.md`), verified against the
  current file, not assumed from memory.
