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

**What a justification looks like:** a justification says why the behaviour is
right, in terms someone could disagree with. "`valid_glob?` returns the same
verdict for `"!["` and `"[abc"` because a validity verdict must not depend on
where matching stopped" is a justification. "`valid_glob?` returns false for
`"!["`" is a restatement of the code with an assertion wrapped round it, and it
is what freezes a bug in place. If the sentence would still be true when the
behaviour was wrong, it is not a justification.

**Watch out:** The gate mutates only the lines your change touched, so it is
usually a couple of minutes, not the whole suite. Changing the spec file of a
module that is already at 100% mutates that module in full — deleting an
assertion touches no source line, and that widening is the only thing standing
between a backfilled module and a quiet unravelling. CI blocks on the same
script; this convention only asks you to see it before CI does.

## Verify

Each of these is checkable from the diff alone, because that is all a reviewer
of the change has:

- Every new or changed example's description says what behaviour is right, not
  which line it reaches.
- Any new entry in `tool/mutate/ignore.txt`, `no-spec.txt`, or `backfill.txt`
  carries a reason a reviewer can disagree with, and the diff shows what it
  exempts.
- A source fix in the diff is named in the commit body.
- No example in the diff calls a function without asserting on its result.
