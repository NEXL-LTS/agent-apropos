# Conventions

Scoped guidance for this sample repo, delivered just-in-time by agent-apropos.

| Layer | For | Trigger | Delivered by |
| --- | --- | --- | --- |
| 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
| 2 Scoped rules | A directory / file type, an API / code construct, or both | A **write** (or, if declared, a **removal**) of a matching **path** and/or matching **content** (regex) | Pre/PostToolUse hooks |
| 3 Intent skills | Task-nature guidance | Semantic skill match | Generated `SKILL.md` |

Each rule doc declares how it is delivered via YAML frontmatter:

```yaml
---
paths: ["src/**"]                     # write to a matching path
contents: ['\bNotImplementedError\b'] # written code matches (PCRE2)
on: [write, removed]                  # events this rule fires on; defaults to [write]
skill: true                           # Layer 3: generate a skill wrapper
description: "Use when ..."           # required iff skill: true
---
```

`paths` and `contents` can combine — the rule fires only when both match. See
`db-audit-rule.md`: it only fires inside `db/**` (not the whole tree) AND only
when the written code calls `conn.execute(` (not every edit under `db/`).

The docs in this directory demonstrate each kind of trigger:

- `src-rule.md` — path-scoped, fires on writes under `src/**`.
- `api-auth-rule.md` / `api-throttle-rule.md` — two path-scoped rules that both
  fire on writes under `api/**`, demonstrating that more than one rule can
  apply to the same file at once.
- `stub-rule.md` — content-scoped, fires when written code raises
  `NotImplementedError`.
- `db-audit-rule.md` — path + content (AND), fires only inside `db/**` when the
  written code calls `conn.execute(`.
- `services-removal-rule.md` — path-scoped with `on: [removed]`, fires when a
  file under `services/**` is deleted rather than written.
- `workflows/add-operation.md` — Layer 3 intent skill, matched by task intent.
