# The mutation gate

`make mutate` rewrites the source your change touched into plausible variants —
*mutants* — and fails when the specs still pass. CI runs the same script on every
pull request as a blocking check.

Coverage proves a line ran. It proves nothing about whether anything asserted on
what the line did, and an agent optimising for a green gate can satisfy 100%
coverage with a spec that calls a function and looks at nothing. `valid_glob?`
had been at 100% coverage since it was written and reported `"!["` as a valid
glob while reporting `"[abc"` invalid, though both are unterminated brackets.

## Running it

```sh
make mutate                                    # the changed lines, same as CI
make mutate ARGS="--base main"                 # against a different base
make mutate ARGS="src/agent_apropos/index.cr"  # one file in full, ignoring the diff
```

The engine is [universalmutator](https://github.com/agroce/universalmutator),
pinned by hash in `tool/mutate/requirements.txt`. It has no coupling to any
language toolchain, which is why it replaced crytic — that compiled against the
Crystal compiler and went stale the moment the toolchain moved.

A run derives the changed files from the merge-base of the PR base and head,
generates mutants, discards any that fail a parse check or a no-codegen build,
then runs the module's sibling spec against each with a timeout. A timeout
counts as killed. Anything that survives its sibling spec is re-checked against
the whole suite, because the narrow run over-reports; a full-suite kill counts.
What still survives is matched against the ignore list and the rest is reported.

## Resolving a survivor

**A survivor is a suspected bug until you can justify the current behaviour.**
The rule is in [`workflows/mutation.md`](conventions/workflows/mutation.md),
which is a skill — it triggers when you commit or open a PR.

| The mutated behaviour is... | Do |
|---|---|
| wrong, and the current behaviour cannot be justified | fix the code, and name the fix in the commit body |
| right | add the pinning spec, with the example's description saying *why* it is right |
| unobservable either way | add a `tool/mutate/ignore.json` entry with its reason |

Reaching for the assertion first is the failure mode this gate exists to
prevent: it is the cheapest path to green, and it would have frozen the
`valid_glob?` bug into the suite as intended behaviour.

## The reviewed lists

Three checked-in JSON files under `tool/mutate/`, each carrying its own `note`.
All three fail the run when an entry goes stale, because an entry that no longer
describes anything is a silent hole in the gate — and a file that will not parse
fails the run too, rather than reading as an empty list.

| File | Holds |
|---|---|
| `ignore.json` | Equivalent mutants, keyed on path, occurrence, and the original and mutated text |
| `no-spec.json` | Tracked source files with no sibling spec, and why they carry nothing to mutate |
| `clean.json` | Source files verified at a 100% mutation score |

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

## How much of a file gets mutated

Touch a file that `tool/mutate/clean.json` does not name and the gate mutates it
**in full**: there is no evidence its untouched lines are pinned, so bringing it
to zero survivors is part of your change. That is the whole backfill programme —
existing code reaches the standard as it is worked on, not through sweeps
somebody has to remember to run.

Touch a file the list *does* name and the gate mutates only your changed lines,
because CI already proved the rest. A run that brings a new file to zero
survivors prints the line to add.

Changing a spec file mutates its module in full either way: deleting an
assertion changes no source line, so a gate that only saw changed source lines
would wave it through.

The list is deliberately a record of what is done rather than what is left. An
entry that is missing costs time — the file gets mutated in full — instead of
silently weakening the gate, and every entry is re-checked the next time that
file is touched.

## Local runs on a drifted toolchain

The full-suite re-check runs `crystal spec`. If your devcontainer's Crystal has
run ahead of the version `ci.yml` pins, that fails to compile `spec/tool/`
(which requires ameba) and the gate aborts with a distinct error rather than
scoring every mutant killed against a red tree. The fix is the drift, not the
gate.
