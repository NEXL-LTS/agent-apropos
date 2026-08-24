# The mutation gate

`make mutate` rewrites each source line your change touched into a plausible
variant — a *mutant* — and fails when the specs still pass. CI runs the same
script on every pull request as a blocking check.

Coverage proves a line ran. It proves nothing about whether anything asserted on
what the line did, and an agent optimising for a green gate can satisfy 100%
coverage with a spec that calls a function and looks at nothing. `valid_glob?`
had been at 100% coverage since it was written and reported `"!["` as a valid
glob while reporting `"[abc"` invalid, though both are unterminated brackets.

## Running it

```sh
make mutate                                    # the changed lines, same as CI
make mutate ARGS="--base main"                 # against a different base
make mutate ARGS="src/agent_apropos/index.cr"  # a whole module (a backfill sweep)
```

The engine is [universalmutator](https://github.com/agroce/universalmutator),
pinned by hash in `tool/mutate/requirements.txt`. It has no coupling to any
language toolchain, which is why it replaced crytic — that compiled against the
Crystal compiler and went stale the moment the toolchain moved.

A run derives the changed lines from the merge-base of the PR base and head,
generates mutants for those lines only, discards any that fail a parse check or
a no-codegen build, then runs the module's sibling spec against each with a
timeout. A timeout counts as killed. Anything that survives its sibling spec is
re-checked against the whole suite, because the narrow run over-reports; a
full-suite kill counts. What still survives is matched against the ignore list
and the rest is reported.

## Resolving a survivor

**A survivor is a suspected bug until you can justify the current behaviour.**
The rule is in [`workflows/mutation.md`](conventions/workflows/mutation.md),
which is a skill — it triggers when you commit or open a PR.

| The mutated behaviour is... | Do |
|---|---|
| wrong, and the current behaviour cannot be justified | fix the code, and name the fix in the commit body |
| right | add the pinning spec, with the example's description saying *why* it is right |
| unobservable either way | add a `tool/mutate/ignore.txt` entry with its reason |

Reaching for the assertion first is the failure mode this gate exists to
prevent: it is the cheapest path to green, and it would have frozen the
`valid_glob?` bug into the suite as intended behaviour.

## The reviewed lists

Three checked-in files under `tool/mutate/`, each documenting its own format.
All three fail the run when an entry goes stale, because an entry that no longer
describes anything is a silent hole in the gate.

| File | Holds |
|---|---|
| `ignore.txt` | Equivalent mutants, keyed on path, occurrence, and the original and mutated text |
| `no-spec.txt` | Tracked source files with no sibling spec, and why they carry nothing to mutate |
| `backfill.txt` | Modules not yet at a 100% mutation score, in sweep order |

## The operator set

`tool/mutate/crystal.rules` transliterates the operator classes universalmutator
ships rather than inventing a set: a score against operators we designed would
attest to less, because the same blind spot that shaped the code would have
shaped the operators. Every shipped rules file is accounted for there, and
`make mutate-rules-spec` enforces that.

Every mutant that fails the compile gate is a compile spent for nothing, so what
matters is how many generated mutants are Crystal at all. Measured against the
same module and the same gate the runner uses, the Crystal rules roughly double
the stock rate:

| Module | Crystal rules | Stock rules |
|---|---|---|
| `src/agent_apropos/matcher.cr` | 26% | 13% |
| `src/agent_apropos/index.cr` | 14% | 10% |

Loop-control insertion holds that number down — `break` and `next` are legal
only inside a loop or a block, so on straight-line code the class yields nothing.
It is carried anyway; dropping an operator because it is inconvenient on our own
code is the self-selection the transliteration rule exists to prevent.

## Backfilling

The per-PR gate only sees changed lines, so existing code reaches the standard
through sweeps run outside it — one module per PR:

```sh
make mutate ARGS="src/agent_apropos/frontmatter.cr"
```

Resolve every survivor, then delete that module's line from
`tool/mutate/backfill.txt` in the same PR. The list shrinking is the progress
report, and a stalled backfill shows up as a list that stopped getting shorter.
Order is set in the file: pure-logic modules first, where a survivor is most
likely a real defect, then the rest by ascending size.

Once a module is off the list, changing its spec file mutates it in full —
deleting an assertion changes no source line, so a gate that only sees changed
source lines would wave it through.

## Local runs on a drifted toolchain

The full-suite re-check runs `crystal spec`. If your devcontainer's Crystal has
run ahead of the version `ci.yml` pins, that fails to compile `spec/tool/`
(which requires ameba) and the gate aborts with a distinct error rather than
scoring every mutant killed against a red tree. The fix is the drift, not the
gate.
