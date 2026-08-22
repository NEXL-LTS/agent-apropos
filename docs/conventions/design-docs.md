---
paths: ["docs/design/**"]
---

# `docs/design/` is for rationale with no natural trigger

**Rule:** Before adding rationale to `docs/design/`, check whether it is
actually tied to a specific, matchable construct: a file (or small set of
files) and/or a content pattern that would fire at exactly the moment
someone touches the code it's protecting. If a natural `paths`/`contents`
trigger exists — per the classification steps in
[`docs/conventions/README.md`](README.md) — write it as a
`docs/conventions/*.md` rule instead, not here. Reserve `docs/design/` for
rationale that is a compendium spanning many files/constructs with no
single trigger point, or that is purely historical/descriptive with no
"don't undo this" implication for a future edit.

**Why:** `docs/design/*.md` is never compiled into the trigger index,
never injected at edit time, and never harvested for `## Verify` criteria
by `agent-apropos review` — it is read only when someone happens to open
it. Protective rationale left here instead of as a triggered convention
sits exactly where a stripped-out comment used to sit: invisible at the
moment it matters, until an edit quietly undoes the thing it was
protecting. `filesystem.cr`'s `O_NOFOLLOW` rationale was originally
written here and had exactly this problem; it moved to a convention scoped to
`paths: ["src/agent_apropos/filesystem.cr"]` + `contents: ['O_NOFOLLOW']` once
we noticed the trigger was obvious — and was deleted outright when the primitive
it governed was retired for the Windows port, which is the other half of the
same discipline: a convention outlives its subject only as a lie.

**Watch out:** Not everything belongs as a convention. A doc spanning many
files with no single precise trigger (e.g. `agent-dialects.md`, a
compendium of per-CLI-agent empirical facts across several files) is a
legitimate design doc — splitting it into artificially narrow
per-fact conventions just to force a trigger would fragment guidance and
add injection noise instead of clarity. The test is whether a natural,
precise `paths`/`contents` match exists that fires at the right moment —
not whether the content could theoretically be reworded as a rule.

## Verify

- New `docs/design/*.md` content that names a specific file/construct and
  implies "don't undo this" has been checked against the classification
  steps in `docs/conventions/README.md` for a natural `paths`/`contents`
  trigger; if one exists, the content lives in `docs/conventions/` instead.
- Content that stays in `docs/design/` is either a multi-file compendium
  with no single trigger point, or purely historical/descriptive.
