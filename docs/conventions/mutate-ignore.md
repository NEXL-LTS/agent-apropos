---
paths: ["tool/mutate/ignore.json"]
---
# An ignore entry needs equivalence, not just "unobservable"

**Rule:** Before adding an entry here, ask *why* the mutation is
unobservable. Two implementations can both be legitimately valid (git
accepts `--verify` before or after the ref on `rev-parse`) — the code is
fine as-is, and the entry is the right call. Or a branch can be provably
*unreachable* given the surrounding logic, not merely unexercised — that's
dead code; delete it instead of documenting it. Or the distinction the
mutant erases can be real and reachable, but redundant with a *downstream
check* that re-derives the same answer regardless — simplify the code to
rely on that check instead of keeping the extra precision upstream.
`git.cr`'s `removed_paths` post-filters every candidate through
`fs.exists?`; a `parse_removed_records` that separately classified staged
deletes, worktree deletes, and rename destinations before adding a path was
redundant with that filter on every one of those distinctions. The fix was
adding every destination and rename/copy source unconditionally and letting
`fs.exists?` filter them, not nine ignore entries explaining why each
distinction didn't matter.

**Why:** An ignore entry for dead code documents debt instead of paying it —
`agents/copilot.cr`'s `upgrade_bash_target` once had a guard that could
never reject anything a later check didn't already reject; deleting it was
the fix, not a reviewed "unobservable" entry. A downstream-masked
distinction rots the same way from the other side: the code still *looks*
load-bearing, and nothing but the ignore-list itself reveals that it isn't.

**Watch out:** Simplify a downstream-masked distinction away only when the
upstream precision buys nothing but documentation value. If it exists to
*avoid* an expensive downstream check at scale (a real syscall or network
call on a hot path) rather than a once-per-invocation call like `git.cr`'s,
keep it — and record that performance reason, not the mutant.

## Verify

- Every entry argues two implementations are valid, or that a distinction
  is masked by a downstream check with no real cost to avoid — never that a
  branch is unreachable (delete that instead) or that a masked distinction
  is actually protecting an expensive call (simplify that instead).
- `occurrence` is the 1-based index of `original` among identically-trimmed
  lines in the file (see `docs/mutation-testing.md`), verified against the
  current file, not assumed from memory.
