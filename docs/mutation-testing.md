# The mutation gate

`make mutate` rewrites each source line your change touched into a plausible
variant — a *mutant* — and fails when the specs still pass. A surviving mutant
means the behaviour on that line is unpinned, and often that the behaviour
itself is wrong.

CI runs the same script on every pull request as a blocking check. It is not
advisory, and it has no bypass switch: a reviewed ignore-list entry is the only
escape, so bypassing the gate always leaves something a reviewer can see.

## Why, given a 100% coverage gate

Coverage proves a line ran. It proves nothing about whether anything asserted on
what the line did. Most of the code here is written by an agent, and so are its
specs — and an agent optimising for a green gate can satisfy 100% coverage with
a spec that calls a function and looks at nothing. The gate reports 100% and the
behaviour is unpinned.

That is not hypothetical. `valid_glob?` had been at 100% line coverage since it
was written and reported `"!["` as a valid glob while reporting `"[abc"`
invalid, though both are unterminated brackets. A mutation run surfaced it in
34 seconds. No amount of line coverage would have.

## Running it

```sh
make mutate                                            # the changed lines, same as CI
make mutate ARGS="--base main"                         # against a different base
make mutate ARGS="src/agent_apropos/index.cr"          # a whole module (a backfill sweep)
```

The engine is [universalmutator](https://github.com/agroce/universalmutator),
pinned by hash in `tool/mutate/requirements.txt` and installed into the
devcontainer image and the CI job from that file. It has no coupling to any
language toolchain, which is the whole reason it is here: the previous attempt
(crytic) compiled against the Crystal compiler and went stale the moment the
toolchain moved.

## What a run does

1. Derives the changed lines from `git diff --unified=0` against the merge-base
   of the PR base and head. Merge-base rather than the base tip, so an
   out-of-date branch does not get mutants for lines it never touched.
2. Generates mutants for those lines only, from `tool/mutate/crystal.rules`.
3. Discards any mutant that does not compile — a parse check first (fast), then
   a no-codegen build of the spec target.
4. Runs the module's sibling spec against each surviving mutant, with a timeout.
   A timeout counts as killed: a spec that hangs on the mutant has distinguished
   it from the original.
5. Re-checks anything that survived its sibling spec against the whole suite. A
   full-suite kill counts as killed — the narrow run over-reports survivors, and
   this removes the false failure without paying full-suite cost on every mutant.
6. Matches what still survives against `tool/mutate/ignore.txt`, and reports the
   rest with path, line, and the original and mutated text.

## Resolving a survivor

The rule is in [`docs/conventions/mutation.md`](conventions/mutation.md), which
is injected at edit time. In short: **a survivor is a suspected bug until you
can justify the current behaviour.**

- **The mutated behaviour is wrong** and the current behaviour cannot be
  justified → fix the code. Name the fix in the commit body. Do not add an
  assertion whose only job is to turn the gate green.
- **The current behaviour is intended** → add the pinning spec, and say in the
  example's description *why* that behaviour is right. That justification is
  what a reviewer checks.
- **The mutant provably cannot change observable behaviour** → add an entry to
  `tool/mutate/ignore.txt` with its reason. It is a suppression and is reviewed
  like one.

Reaching for the assertion first is the failure mode this gate exists to
prevent: it is the cheapest path to green, and it would have frozen the
`valid_glob?` bug into the suite as intended behaviour.

## The reviewed lists

Three checked-in files under `tool/mutate/`, each with its format and rules
documented in its own header. All three are checked for staleness on every run,
because an entry that no longer describes anything in the tree is a silent hole
in the gate:

| File | Holds |
|---|---|
| `ignore.txt` | Equivalent mutants, keyed on path, occurrence, original and mutated text, with a reason |
| `no-spec.txt` | Tracked source files with no sibling spec, and why they carry nothing to mutate |
| `backfill.txt` | Modules not yet at a 100% mutation score, in sweep order |

## The operator set

`tool/mutate/crystal.rules` is a **transliteration** of the operator classes
universalmutator ships, not a set we designed. A 100% score against operators we
invented would attest to less, because the same blind spot that shaped the code
would have shaped the operators. Every rules file the engine ships is accounted
for in that file — either carried across into Crystal syntax under a `# SOURCE:`
block, or declined with a `# NO CRYSTAL COUNTERPART` reason. `make
mutate-rules-spec` enforces that accounting. Adding or removing an operator
class is a reviewed change.

The stock universal rules produce C-shaped output: on
`src/agent_apropos/matcher.cr` they generated 145 mutants of which 16 compiled,
an 11.0% pass rate, so nine mutants in ten were a wasted compile. The Crystal
rules currently measure **54.5%** on the same module (304 of 558). What still
holds that number down is loop-control statement insertion: `break` and `next`
are only legal inside a loop or a block, so the class spends a compile per line
in straight-line code and yields nothing there. It is carried anyway — the class
is the engine's, not ours to drop because it is inconvenient on one module.

## Backfilling

The per-PR gate only sees changed lines, so existing code reaches the repo-wide
standard through sweeps run outside the gate — one module per PR:

```sh
make mutate ARGS="src/agent_apropos/frontmatter.cr"
```

Resolve every survivor by the rule above, then delete that module's line from
`tool/mutate/backfill.txt` in the same PR. The list shrinking is the progress
report; there is no separate status to keep up to date, and a stalled backfill
is visible as a list that stopped getting shorter.

Order is set in `backfill.txt`: the pure-logic modules first, where a survivor
is most likely to be a real defect, then the rest by ascending file size so the
early sweeps give real survivor-rate data cheaply.

Once a module is off the list, changing its spec file mutates it in full. That
is deliberate: deleting an assertion changes no source line, so a gate that only
sees changed source lines would wave it through.

## Local runs on a drifted toolchain

The full-suite re-check runs `crystal spec`. If your devcontainer's Crystal has
run ahead of the version `ci.yml` pins, `crystal spec` fails to compile
`spec/tool/` (which requires ameba) and the gate aborts with a distinct error
rather than scoring every mutant killed against a red tree. That is the correct
behaviour; the fix is the toolchain drift, not the gate.
