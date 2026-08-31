# Per-agent dialect notes

Empirical, hard-won facts about each wired CLI agent's hook/skill dialect that
don't fit a spec name or a Crystal identifier — confirmed against real agent
behavior, not just vendor docs, so they're not safely re-derivable by reading
the code alone. One section per file in `src/agent_apropos/agents/`.

## Gemini (`agents/gemini.cr`)

Gemini CLI's hook `timeout` is passed straight to JS `setTimeout()` —
milliseconds, not seconds like Claude Code's own hook `timeout`. Using the
same literal `10` here previously gave Gemini's `AfterTool` hooks a
10-*millisecond* budget, well under the ~3-4ms `agent-apropos` itself needs
just to spawn — any load at all (e.g. another CLI agent running
concurrently) tipped it over, so `agent-apropos hook pre`/`post` would
intermittently get SIGTERM'd and reported as failed. `HOOK_TIMEOUT =
10_000_i64` is the same 10-second intent, expressed in Gemini's own unit;
`with_missing_hooks`/`with_missing_read_hook` refresh an already-wired
command's stale `timeout` on every `init` re-run rather than only appending
missing commands, specifically so a repo that wired Gemini before this fix
picks up the corrected value on its next `init` instead of staying stuck on
the broken one forever.

## Payload parsing (`hooks/payload.cr`)

`spec/fixtures/hook_payloads/` — not `Payload` itself — is the authoritative
record of each dialect's field names; the parser just follows the fixtures.
Field names are the part of every dialect's contract most exposed to
upstream schema drift, so when a dialect's shape changes, update the
fixture first and let the failing spec drive the parser change.

Codex's `apply_patch` patch envelope is not a standard unified diff:
sections start with `*** Add File: <path>`, `*** Update File: <path>`
(optionally followed by a `*** Move to: <path>` rename), or `*** Delete
File: <path>` — this last one per OpenAI's public `apply_patch` format spec,
not itself independently captured live like the Add/Update shapes were —
each running until the next such marker or `*** End Patch`. Only Add/Update
sections become a `FileEdit`: a Delete has no newly written content to match
a `contents` rule against, and no other wired agent's hooks fire on a pure
delete either, so skipping it keeps Codex's scope consistent with the rest of
the layer model.

## Copilot (`agents/copilot.cr`)

GitHub Copilot CLI's `preToolUse` output schema is `permissionDecision`/
`modifiedArgs` only — no context field — so, like Gemini's `AfterTool`,
scoped rules are wired onto `postToolUse` instead: a `view`-only matcher
group carrying just `agent-apropos hook pre`, and a `create|edit` group
carrying both `pre` and `post`. The `view` group injects nothing (a read
never does); it exists so a convention doc Copilot reads for itself is
recorded as already in context. `postToolUse` is also the *right* event for
that: it fires only after the read succeeded, so a denied or failed read
cannot mark a doc delivered when the model never saw it. Claude's `Read` and
OpenCode's `read` are wired onto their own post-execution events
(`PostToolUse`, `tool.execute.after`) for the same reason, even though both
have a usable pre-execution event — this is the one place agent-apropos
deliberately gives up early delivery, because a read has nothing to deliver.

`.github/hooks/agent-apropos.json` is written with no bridge script, unlike
Claude/Gemini's shared settings file: Copilot CLI loads every
`.github/hooks/*.json` in the repo independently, so this file is entirely
agent-apropos-owned, and `Hook::Payload`/`Hook.emit` understand Copilot's
wire dialect natively — `toolArgs` as a JSON-encoded *string* keyed by
`path`/`file_text`/`old_str`/`new_str`, and a flat `additionalContext` reply
instead of the `hookSpecificOutput` envelope every other wired agent expects.
This shape was confirmed against a real captured Copilot CLI hook payload,
not upstream docs — Copilot's own reference types `toolArgs` as `unknown`.

Copilot's shell tool is `bash` — lowercase, unlike Claude/Codex's capitalized
`Bash` — confirmed against a real captured `postToolUse` payload for a `rm`
command (`spec/fixtures/hook_payloads/copilot_post_tool_use_bash.json`);
`toolArgs` carries `command`/`description` keys instead of a path. Removal
detection (`Hook::Payload#command`) reads this the same way it reads
`tool_input.command` for the other dialects. Because Copilot's own hook
config has no grouped-matcher shape (each `postToolUse` entry is a flat
`{matcher, command}` pair, not Claude's `{matcher, hooks: [...]}` groups),
`Agents::Copilot#sync_shell_hook` is its own implementation rather than a
call into `Agent#sync_standard_shell_hook`, wiring `agent-apropos hook
pre`/`post` onto a `bash`-matched entry alongside the existing `view`/
`create|edit` ones.

## OpenCode (`agents/opencode.cr`)

OpenCode's shell tool is `bash` — confirmed against a real captured
`tool.execute.before`/`tool.execute.after` payload pair for a `rm` command;
its args carry `command`, not `filePath`. `Payload` needs no dialect-specific
change for this: the plugin's own `makePayload` already normalizes every
tool's args into the same snake_case `tool_input` shape Claude/Codex use
(`file_path`, `content`, ...), so adding `command` there is enough — `Payload
#command` (`tool_input.try(&.command) || copilot_args.try(&.command)`)
already reads it the same way it reads Codex's `apply_patch` command.

The plugin file is the one wired artifact with no existing-content
preservation at all — its own header says "do not edit, regenerate" and
`config_content` never reads `existing` — so `Agents::OpenCode#sync_shell_hook`
doesn't patch anything in place: it re-renders the same template with `bash`
added to (or left out of) both tool-name allowlists and diffs the result
against what's already there, detecting a carried `--allow-outside-repo` by
substring search on `existing` rather than parsing JSON, since there's no
JSON here to parse.

## Codex (`agents/codex.cr`)

Codex CLI's `PreToolUse`/`PostToolUse` envelope and reply schema mirror
Claude Code's almost exactly — down to naming its shell tool `Bash`, matching
Claude's own tool name — including `PreToolUse`'s own
`hookSpecificOutput.additionalContext`, so a rule lands *before* the write
here, the same as Claude, unlike Gemini/Copilot's post-only degradation.
Codex's own hook `timeout` field is seconds, like Claude Code's too. Both
facts were confirmed against a real captured Codex hook payload, not
upstream docs.

Codex's file-editing tool, `apply_patch`, is structurally different from
every other wired agent's: a single call's `tool_input.command` is a patch
envelope (`*** Begin Patch` / `*** Add File:` / `*** Update File:` / `***
End Patch`) that can bundle several files' Add/Update sections into one
call. `Hook::Payload#file_edits` and its `ApplyPatch` parser handle this;
every other wired dialect is exactly one file per call.

Codex has no separate structured "read" tool the way Claude's `Read` or
Gemini's `read_file` are — it reads files by shelling out through its own
`Bash` tool (`cat`/`sed`/`rg`), which carries no `file_path` — so
`Codex#read?` is unconditionally false and a convention doc Codex reads for
itself cannot be recorded as already in context; only `apply_patch` is
matched.

## Skill wrapper delivery (`skills.cr`)

The generated `SKILL.md` wrapper is a thin pointer back to the source doc
("Read `path` and follow it") when the source lives inside the repo, but
inlines the doc's full body when the source lives outside it (a custom
`conventions_dir`, e.g. `../shared-docs`). A pointer this thin only works if
the model actually follows it — reliable for an in-repo path (it looks like
anything else in the project), but observed *not* to be for an external one
with `../` segments outside the visible workspace tree, where the model has
no reason to trust or prioritize reading it.

Codex CLI's own `SKILL.md` frontmatter shape (`name`/`description`) happens
to be identical to Claude's — confirmed live: a `.codex/skills/<slug>/SKILL.md`
copy of the generated Claude wrapper was picked up by a real Codex CLI run,
where the same content placed only under `.claude/skills/` was not.
