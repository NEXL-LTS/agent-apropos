---
paths: ["src/**/*.cr", "spec/**/*_spec.cr"]
---

# A survivor is a suspected bug

**Rule:** Before you push, run `make mutate`. If a mutant survives, do not
reach for an assertion first. Decide whether the mutated behaviour is *wrong*.
If you cannot justify what the code currently does, fix the code and name the
fix in the commit body. Only when the current behaviour is genuinely intended
do you add the pinning spec — and then the example's description says why that
behaviour is the right one, not merely that it is the behaviour. A mutant that
provably cannot change observable behaviour gets a reviewed entry in
`tool/mutate/ignore.txt` with its reason. There is no third option and no
bypass switch.

**Why:** The 100% line-coverage gate proves a line ran; it proves nothing about
whether anything looked at the result. An agent optimising for a green gate can
satisfy coverage with a spec that calls a function and asserts nothing, and the
gate will report 100% over unpinned behaviour. `valid_glob?` sat at 100%
coverage from the day it was written and reported `"!["` valid and `"[abc"`
invalid, though both are unterminated brackets — a mutation run found it in 34
seconds. Reaching for the assertion first is what would have frozen that bug
into the suite as intended behaviour.

**Watch out:** The gate mutates only the lines your change touched, so it is
usually a couple of minutes, not the whole suite. Changing the spec file of a
module that is already at 100% mutates that module in full — deleting an
assertion touches no source line, and that widening is the only thing standing
between a backfilled module and a quiet unravelling. CI blocks on the same
script; this convention only asks you to see it before CI does.

## Verify

- Every survivor on the changed lines is resolved by a code fix, a justified
  pinning example, or a reviewed `tool/mutate/ignore.txt` entry.
- A survivor cleared with a new spec has a written justification that the
  current behaviour is intended, on the example that pins it.
- A survivor resolved by fixing the code names the fix in the commit body.
- No spec was added whose only purpose is to execute a line.
