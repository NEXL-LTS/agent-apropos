---
skill: true
description: "Use when the user asks to commit, push, or open a pull request, or when a mutation gate run reports a surviving mutant, to resolve survivors by fixing code rather than by pinning whatever the code happens to do."
---

# A survivor is a suspected bug

**Rule:** Run `make mutate` before you commit. If a mutant survives, do not
reach for an assertion first. Decide whether the mutated behaviour is *wrong*.
If you cannot justify what the code currently does, fix the code and name the
fix in the commit body. Only when the current behaviour is genuinely intended
do you add the pinning spec, with the example's description saying why that
behaviour is right. A mutant that provably cannot change observable behaviour
gets a reviewed entry in `tool/mutate/ignore.txt`. There is no fourth option
and no bypass switch.

**Why:** The 100% line-coverage gate proves a line ran, not that anything looked
at the result. An agent optimising for a green gate can satisfy coverage with a
spec that calls a function and asserts nothing. `valid_glob?` sat at 100%
coverage from the day it was written and reported `"!["` valid and `"[abc"`
invalid, though both are unterminated brackets. Reaching for the assertion first
is what would have frozen that bug into the suite as intended behaviour.

**What a justification looks like:** it says why the behaviour is right, in
terms someone could disagree with. "A validity verdict must not depend on where
matching stopped" is a justification. "`valid_glob?` returns false for `"!["`"
restates the code. If the sentence would still be true when the behaviour was
wrong, it is not a justification.

**Watch out:** `make check` does not run the gate, and CI blocks on it. The run
covers only the lines you changed, so it is usually a couple of minutes —
except that changing the spec file of a module already at 100% mutates that
module in full, which is what stops its assertions from being quietly deleted.

## Verify

- Every new or changed example's description says what behaviour is right, not
  which line it reaches.
- Any new entry in `tool/mutate/ignore.txt`, `no-spec.txt`, or `backfill.txt`
  carries a reason a reviewer can disagree with.
- A source fix is named in the commit body.
- No example calls a function without asserting on its result.
