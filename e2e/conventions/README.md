# Conventions

Scoped guidance for this sample repo, delivered just-in-time by agent-apropos.

| Layer | For | Trigger | Delivered by |
| --- | --- | --- | --- |
| 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
| 2 Path-scoped | A directory / file type | File **path** | PreToolUse hook |
| 3 Construct-scoped | An API / code construct | Written **content** (regex), optionally AND path | PostToolUse hook |
| 4 Intent skills | Task-nature guidance | Semantic skill match | Generated `SKILL.md` |

Each rule doc declares how it is delivered via YAML frontmatter:

```yaml
---
paths: ["src/**"]                     # Layer 2
contents: ['\bNotImplementedError\b'] # Layer 3 (PCRE2)
skill: true                           # Layer 4
description: "Use when ..."           # required iff skill: true
---
```

`paths` and `contents` can combine — the rule fires only when both match. See
`db-audit-rule.md`: it only fires inside `db/**` (not the whole tree) AND only
when the written code calls `conn.execute(` (not every edit under `db/`).

The docs in this directory demonstrate one convention per layer, plus one
combined path+content example:

- `src-rule.md` — Layer 2, fires on edits under `src/**`.
- `api-auth-rule.md` / `api-throttle-rule.md` — two Layer 2 rules that both
  fire on edits under `api/**`, demonstrating that more than one path-scoped
  rule can apply to the same file at once.
- `stub-rule.md` — Layer 3, fires when written code raises `NotImplementedError`.
- `db-audit-rule.md` — Layer 3 (path + content, AND), fires only inside
  `db/**` when the written code calls `conn.execute(`.
- `workflows/add-operation.md` — Layer 4 skill, matched by task intent.
