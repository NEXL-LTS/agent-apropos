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

Three more arguments look like equivalence but aren't:

- **"Every caller passes it explicitly."** Then the default is dead: make
  the parameter required, and the mutant can't be generated.
- **"The input always looks like X."** An envelope always ends in
  `*** End Patch`, or a read always names a single file. That is an
  assumption about callers, not equivalence: pin the behaviour on the
  violating input with a spec, or restructure so the assumption isn't
  load-bearing. An index loop that only works on well-formed input becomes a
  single forward pass that has no start index to mutate.
- **"These happen to agree."** `event == :pre` and `event >= :pre` agree
  only because `"post"` sorts before `"pre"`. Make the domain a closed type
  (an `enum` with an exhaustive `case … in`) so there is no comparison to
  flip.

A mutant the operator set produces regardless of the code is a fix in
`tool/mutate/crystal.rules`, not an entry. Examples: a whitespace-only
argument swap, digits inside a type name (`Int32` → `Int-1`), or `return` →
`return nil`. And when several entries cluster in one method, the method's
shape is the problem; restructure it. Eight entries for `next`/`break`
inside `emit`'s nested `JSON.build` blocks went away when the body became a
`NamedTuple#to_json`.

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

A `reason` is a claim, not proof: reproduce it before writing it down. One
entry said removing a `content = nil` seed above a block was a no-op
because Crystal types the variable as nilable. In fact, a variable first
assigned inside a block resets on every iteration, so the mutant dropped
every content match after the first. A three-line program refutes that
reason, and the entry hid a missing spec. In a PR stack, re-check every
entry against the later PRs too. "A Delete section never contributes
anything" held in U4 and stopped holding one PR later, when Delete sections
became removals, while the entry went on suppressing the mutant.

## Verify

- Every entry argues two implementations are valid, or that a distinction
  is masked by a downstream check with no real cost to avoid — never that a
  branch is unreachable (delete that instead) or that a masked distinction
  is actually protecting an expensive call (simplify that instead).
- No entry rests on how callers or inputs happen to behave today: a
  default that is never used, an input shape that is always present, or
  values that agree by coincidence. Each of those is a code change or a
  pinning spec.
- No entry covers a mutant the operator set generates regardless of the
  code; that is a `crystal.rules` fix.
- Each `reason`'s language-semantics claim was reproduced, not recalled,
  and still holds in every later PR of the stack.
- `occurrence` is the 1-based index of `original` among identically-trimmed
  lines in the file (see `docs/mutation-testing.md`), verified against the
  current file, not assumed from memory.
