# Conventions — the Agent Documentation Structure Standard

This directory is the **single source of truth** for scoped guidance — the
judgment calls and directional practices that a linter or formatter cannot
enforce. It is also the normative definition of the layered documentation
structure agent-apropos implements; agent-apropos dogfoods that structure on itself here.

Universal, always-apply rules live in the root [`AGENTS.md`](../../AGENTS.md), not
here. Anything a tool can enforce lives in that tool (`crystal tool format`,
`ameba`), not here.

## Goal

Replace one large, always-loaded instruction file with a layered system where
each piece of guidance is delivered by the cheapest mechanism that reliably
triggers it. Guidance should arrive **just-in-time**, scoped to the moment it
applies, instead of being front-loaded and forgotten.

## Scope: complements enforcement, does not replace it

This system is not a substitute for linters, formatters, type checkers, or CI.
Anything those tools can enforce deterministically belongs in them, not in
convention docs. This structure exists for guidance that is hard to enforce
mechanically — judgment calls, trade-offs, directional practices, workflow
knowledge.

A convention doc can also serve as an **incubator**: a practice starts here as
prose, and once it is well understood and its violations are recognizable, it
graduates into a lint rule, formatter setting, or generator, and the prose is
deleted. Movement is one-directional — from docs into tooling, never the reverse.

## The three layers

Every convention, instruction, or practice is classified into exactly one layer.

| Layer | For | Trigger | Delivered by |
| --- | --- | --- | --- |
| 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
| 2 Scoped rules | Guidance for a directory / file type, an API / code construct, or both | A **write** to a matching **path** and/or matching written **content** (regex) | Pre/PostToolUse hooks |
| 3 Intent skills | Task-nature guidance (semantic) | Claude Code skill match | Generated `.claude/skills/*/SKILL.md` |

**Layer 1 — root file** (`AGENTS.md`, `CLAUDE.md` symlinked to it). Contains only
a short project description, exact build/test/lint commands, universal rules that
apply to every task, and a one-line map to `docs/conventions/`. Hard budget: keep
well under 150 lines. Every line must pass "would removing this cause a mistake on
a typical task?" Imperative voice; pair every prohibition with the alternative
("Never X; do Y instead"). No style rules a formatter enforces.

**Layer 2 — scoped rules.** One markdown file per concern in
`docs/conventions/`. A rule declares the `paths:` it applies to, the `contents:`
regex the written code must match, or both — declaring both ANDs them, which
restricts where a content match counts (e.g. flag `update_all` only in `app/**`,
not one-off scripts). Where a lint rule could detect the construct but the right
response needs judgment, an advisory (warn-level) lint rule whose message points
to the rule file is preferred over prose alone.

Scoped rules are injected **only when the agent writes**. A read injects nothing:
it carries no intent — a model reads plenty of files it will never edit — and
each rule is injected at most once per session, so spending that one injection on
an exploratory read wastes it. Reads do one thing, which is to *suppress*: if the
agent reads a convention doc itself, the doc is in context verbatim, so no later
write re-injects it. Suppression is deliberately conservative — it needs a read
that both completed and covered the whole doc, so the read tools are wired on
each agent's *post*-execution event (a denied or failed read never reaches it)
and a read bounded by an offset or a limit is ignored.

**Layer 3 — intent skills.** For guidance triggered by the nature of a task, not
its path or content ("doing a data migration", "touching billing"). The doc lives
in `docs/conventions/workflows/` and opts in via `skill: true` + a `description:`
starting with "Use when…". Skills are **generated, not hand-written**: `agent-apropos
generate` emits a thin `.claude/skills/<slug>/SKILL.md` wrapper (description +
pointer to the source doc) — or, when `conventions_dir` (see below) points
outside the repo, the doc's full body inlined instead, since a model can't be
relied on to follow a pointer to a path outside its own workspace tree. Never
edit a wrapper — edit the source doc. Keep skill docs under 500 lines; split
large workflows. Semantic triggering has a miss rate, so anything that *must*
always apply cannot live only here.

## Frontmatter

Each rule doc declares how it is delivered via YAML frontmatter:

```yaml
---
paths: ["src/**"]              # inject when writing to a matching path
contents: ['\bSTDIN\b']        # inject when written code matches (PCRE2)
skill: true                    # Layer 3: generate a skill wrapper
description: "Use when ..."    # required iff skill: true; must start with "Use when"
---
```

Combination semantics:

- `paths` only → fires on any write to a matching path
- `contents` only → fires when written code matches, anywhere
- `paths` + `contents` → **AND**: both must match
- `skill: true` is independent and may combine with either
- no frontmatter → reference-only: reachable by link, never triggered

A `contents` rule needs the written content to match against. When the payload
carries no content and the file cannot be read, the rule stays silent rather than
firing on a guess.

## Writing a rule

- One concern per file. Keep it as short as possible — injected rules that are
  tight get read; long ones get skimmed.
- State **what** the rule is, **why** it exists (the reason is how an agent
  generalizes to edge cases), and a **verification criterion**.
- Add an optional `## Verify` heading; `agent-apropos review` harvests it as a review
  checklist item.

## Classifying an instruction

For each instruction, ask in order — the most deterministic trigger wins
(tooling > path > content > intent > always-loaded):

1. **Can tooling enforce it** (formatter, linter, type checker, blocking hook)? →
   Move it to tooling; delete the prose.
2. **Is it universal** — every task in the repo? → Layer 1, subject to the budget.
3. **Determined by file location?** → Layer 2 rule with `paths:`.
4. **Determined by a code construct or API usage?** → Layer 2 rule with
   `contents:` (plus `paths:` to narrow where it counts, and an advisory lint
   rule if detection is feasible).
5. **Determined only by task intent?** → Layer 3 skill.
6. **None of the above / stale / describes the project as it used to be?** → Delete.

## The generation pipeline and review

`agent-apropos generate` walks `docs/conventions/` and compiles the frontmatter into a
cached **trigger index** (`.cache/agent-apropos/index.json`, gitignored, rebuilt only
when a doc's hash changes) and the committed **skill wrappers**. `agent-apropos generate
--check` is the CI gate: it fails if the committed wrappers drift from what the
current docs produce, so a stale or hand-edited `SKILL.md` blocks the merge.

`docs/conventions/` is the default location, not a hardcoded one: an
`agent-apropos.yml` at the repo root can set `conventions_dir` to any other path,
relative or absolute, in or out of the repo (see the root [`README.md`](../../README.md#configuration)).
Every command above resolves it the same way.

The same frontmatter doubles as a **review manifest**: `agent-apropos review` resolves
which conventions apply to a diff exactly as the edit-time hooks do — path-match
the changed file, content-match against its added lines — and turns each rule's
`## Verify` criterion into a review checklist item. Review prompts therefore carry
zero copies of the conventions; one source serves authoring, editing, and review.

## Quality bar

- Root file under budget, containing zero rules that tooling enforces.
- Every rule file: one concern, as short as possible, with the *why* and a
  verification criterion.
- Every Layer 2 file declares at least one path or content trigger.
- Every skill description passes the "Use when…" precision test; all `SKILL.md`
  files are generator output, never hand-edited, with no guidance duplicated from
  `docs/conventions/`.
- `agent-apropos generate --check` and `agent-apropos lint` pass; nothing is silently dropped.

> Delivery note: this repo self-hosts. Rules here are compiled and injected by
> `agent-apropos` itself — on PreToolUse and PostToolUse — via the hook
> entries in `.claude/settings.json` and `.codex/hooks.json`. Run `make install` so the
> `agent-apropos hook pre`/`agent-apropos hook post` commands resolve on PATH;
> `agent-apropos doctor` checks the wiring.
