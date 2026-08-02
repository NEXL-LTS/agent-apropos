---
paths: ["src/**/*.cr"]
contents: ['#(?!\{)']
---

# Comments are a smell; names and specs are the source of truth

**Rule:** Don't explain what a class, method, or module does — or why — in a
comment. If a name doesn't say what something is for, rename it until it does.
If a behavior, edge case, or invariant needs stating, put it in a spec example
whose description names the reason (`it "rejects an id that would overflow
the filesystem's 255-byte name limit"`), not in a comment above the code.
`Apropos/CommentBlock` only mechanically fails on two or more consecutive
comment-only lines — a lone one-liner still compiles clean — but the target
is zero: treat a single line as legitimate only when it's an
`ameba:disable`/`ameba:enable` directive; anything else is a name or a spec
that hasn't been written yet.

**Why:** A comment drifts from the code the moment either one changes without
the other, and nothing forces them back into sync — a spec fails loudly when
it goes stale, a comment just sits there and lies. Pushing the "why" into a
spec description keeps a single, executable source of truth for intent; the
same discipline that keeps `crystal spec` honest keeps documentation honest.

**Watch out:** Some rationale is architectural and has no natural spec home —
why one CLI agent's hook wiring differs from another's, why a constant is
sized the way it is against an external limit. That kind of cross-cutting
design rationale belongs in `docs/design/` (linked from the module, not
repeated inline), not deleted outright and not smuggled back in as a comment
block.

## Verify

- No `src/**/*.cr` file has two or more consecutive comment-only lines
  (enforced by `Apropos/CommentBlock`; see `.ameba.yml`).
- Behavior and edge cases removed from a deleted comment reappear as a spec
  example named after the reason, not as a restatement of the code.
- Rationale with no spec home is relocated to `docs/design/`, not dropped.
