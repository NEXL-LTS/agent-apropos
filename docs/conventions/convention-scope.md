---
paths: ["docs/conventions/**/*.md"]
---
# A convention states judgment; a spec states fact

**Rule:** Before adding a rule doc, or a claim inside one, check whether the
content is actually a deterministic, verifiable behavior — an exact field
order, a command's exact output shape, an off-by-one edge case — rather than
a judgment call, trade-off, or directional practice that needs the *why* to
generalize to a case nobody anticipated. A deterministic fact doesn't
generalize; it's simply right or wrong, and a spec example (ideally a
real-repo or adversarial one, not a happy-path restatement) is what proves
it's right on every run. Write that as a spec first, per
[`specs.md`](specs.md); write the convention doc only for the judgment that
surrounds it, if any is left once the fact itself is pinned.

**Why:** [`README.md`](README.md)'s own classification steps already say a
tool-enforceable fact belongs in tooling, not prose — a spec *is* that
tooling for a deterministic behavior. Unlike a convention doc, which sits
there until someone happens to have it injected and read it, a spec fails
loudly the moment the behavior drifts. `git-status-porcelain.md` stated the
exact reversed field order `git status --porcelain -z` uses for a
rename/copy record — correct, but entirely re-derivable from
`spec/agent_apropos/git_spec.cr`'s real-repo rename/copy specs, which already
pin it and would fail the moment it drifted. It was deleted outright once
that redundancy was noticed, the other half of the discipline
[`comments.md`](comments.md) already applies to comments in source.

**Watch out:** Not every empirical fact should move to a spec. Architectural
rationale that doesn't reduce to one pinned assertion — why a design choice
was made, reasoning that spans several call sites — is still prose's job:
a convention doc if a natural trigger exists, [`docs/design/`](../design/)
if not, per [`design-docs.md`](design-docs.md). The test is whether a spec
assertion alone already fully captures the fact, leaving nothing for a
reader to learn beyond "the code does X." If the doc's real content is *why*
the code does X, or what breaks if a future edit changes it, that's still a
convention's job, not a spec's.

## Verify

- The doc's core content is a judgment call, trade-off, or directional
  practice — not a deterministic fact that a spec example already pins, or
  should.
- Any deterministic behavior the doc states has a corresponding spec example
  that would fail if the fact were false; where the spec alone fully
  captures it, the doc is deleted rather than left as unenforced restatement.
