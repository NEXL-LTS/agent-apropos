# agent-apropos end-to-end test

A [bats-core](https://github.com/bats-core/bats-core) suite that runs agent-apropos
against live Claude Code, OpenCode, GitHub Copilot CLI, and Codex CLI by
default (Gemini CLI is supported but opt-in — see [Options](#options) — since
even a healthy call has been observed taking 30-60s, and a real edit-task
prompt over 180s) and asserts what the model actually writes. It is organized
**by trigger kind**; each case runs the same with-agent-apropos / without-agent-apropos
contrast for every enabled CLI.

## Structure

```
tests/
  helpers.bash  # sample scaffolding, agent-apropos-on-PATH, agent registry, live runners
  layers.bats   # all cases, each grouped with its expected artifact/prompt/target
```

`layers.bats` holds every case's expected artifact, prompt, target file, and
the `register_live_tests` call that generates its tests — grouped together so
a case's full intent reads in one place instead of hopping between files.
Each case registers a with/without pair of live tests **per CLI agent** in
`E2E_AGENTS` (`helpers.bash`); adding a new CLI agent means adding one entry
to that registry plus a `require_live_<x>`/`run_<x>` helper pair, not a new
per-case test.

[`project/`](./project) is a sample codebase with a convention document for
every trigger kind. Each convention is a realistic project rule — a tracing
decorator, a custom exception, a registry call, an audit wrapper — naming a
specific module/symbol that only exists because the rule said so. A model
can't produce it by chance, but unlike an arbitrary marker token it's not
inert either: a pass proves the convention's *behavior* landed, not just that
a string got copied. Cases sit on non-overlapping paths so each expected
artifact is attributable to exactly one convention — except the "two rules,
one file" case, which deliberately overlaps `api-auth-rule.md` and
`api-throttle-rule.md` on the same `api/**` path to prove two path-scoped
rules can both fire on one edit. That pair is also deliberately
counter-intuitive: throttling must wrap *outermost*, above auth, so an
unauthenticated flood is rejected before it reaches the auth check — the
opposite of the "auth gates first" instinct — which a model can only get
right by actually reading both rule docs, not by guessing a plausible-looking
stacking order.

The rule docs themselves live in [`conventions/`](./conventions), a sibling
of `project/` — outside the sample's own git repo entirely, pointed at via
`project/agent-apropos.yml`'s `conventions_dir`. That's not incidental: a CLI
agent's own auto-included directory/file listing of its workspace can only
ever show what's inside the workspace, so if the docs lived under
`project/` a sufficiently curious model could discover them (and the fact
that it's being tested) by exploring its own file tree — regardless of
whether agent-apropos's hooks are wired at all. Keeping them external means the
*only* channel that can deliver a rule's content into a live run is agent-apropos's
hooks. `new_sample()` (`tests/helpers.bash`) points the copied sample's
`agent-apropos.yml` at the real `conventions/` for "with" and at a directory that
doesn't exist for "without" — the scoped rules then simply have nothing to match,
and there's nothing to find by exploring either. The module each rule points
to (the decorator, exception, registry, audit wrapper) is still stripped
from `project/` in the without-agent-apropos control, since that one *is* reachable
by exploring the sample's own tree.

| Case | Trigger | Convention | Expected artifact | Target file |
| --- | --- | --- | --- | --- |
| Path rule | writing `src/**` | new functions wrapped in `@trace_call` | `@trace_call` | `src/util.py` |
| Path rules (two) | writing `api/**` | new handlers wrapped in both `require_auth` and `rate_limited`, outermost | `require_auth`, `rate_limited` | `api/handlers.py` |
| Content rule | writing `NotImplementedError` | stubs raise `StubNotImplemented` instead | `StubNotImplemented(` | `scripts/jobs.py` |
| Path+content rule (AND) | writing `db/**` AND writing `conn.execute(` | queries go through the audit wrapper | `audited_query(` | `db/queries.py` |
| Intent skill | "add an arithmetic operation" | new ops register in the dispatch table | `register_operation(` | `lib/calc.py` |
| Removal rule | deleting a file under `services/**` | the deletion is recorded in a decommission log | `Decommissioned: heartbeat.py` | `services/DECOMMISSIONED.md` |

## Running

```sh
make e2e          # or: bash e2e/run.sh
```

**Authenticate with each CLI first.** The live tests need a working, logged-in
`claude`, `opencode`, `gemini`, and `copilot` — see [CI-safety and credentials](#ci-safety-and-credentials)
below for how. Skip this and the corresponding live tests don't fail; they
just skip cleanly, which can look like a pass at a glance.

`bats` and its `bats-support`/`bats-assert` libraries ship in the devcontainer
image (resolved via `BATS_LIB_PATH`), so nothing is fetched at run time.
Before invoking `bats`, `run.sh` runs `agent-apropos init --tool claude --tool
opencode --tool gemini --tool copilot` and `agent-apropos generate` against `project/`
itself (both with `--allow-outside-repo`, since `project/agent-apropos.yml`
points `conventions_dir` outside the sample repo — see above; `Config`
refuses to resolve an escaping conventions_dir without that flag, and `init`
also bakes it into the wired hook commands so the live hook invocations below
keep working), so its hook wiring (`.claude/`, `.opencode/`, `.gemini/`, `.github/hooks/`)
is always freshly generated rather than committed (see `project/.gitignore`) —
that way the fixture is fully wired regardless of which agents happen to be
installed on the machine running the suite. `run.sh` invokes `bats` on
[`tests/`](./tests); extra flags pass through, e.g. `bash e2e/run.sh --filter 'Path rule'`.

## The two tests per case, per agent

Each test copies the sample into an isolated temp git repo (bats'
`BATS_TEST_TMPDIR`, outside this repo) with a freshly built `agent-apropos` on PATH.
For each case, every agent in `E2E_AGENTS` runs the same live pair:

1. **with agent-apropos (live).** Run the CLI against the wired sample and assert the
   expected artifact lands in the edited file.
2. **without agent-apropos (live control).** Run the same prompt with agent-apropos removed
   and assert the expected artifact does **not** appear.

Deterministic delivery — that a hook payload maps to the right rule, or that
`generate` writes the right skill wrapper — is covered by the Crystal spec
suite (`spec/agent_apropos/hook_spec.cr`, `spec/integration/hook_spec.cr`,
`spec/agent_apropos/generate_spec.cr`, `spec/integration/generate_spec.cr`), not
here. This suite only exists to prove a real CLI agent's own output is
actually steered.

## CI-safety and credentials

The live checks require the `claude` / `opencode` / `gemini` / `copilot` CLI
and valid credentials. When one is absent or unauthenticated, its tests
**skip cleanly** and the run still exits `0`; the deterministic checks always
run. This is why the e2e is not wired into `make check` or CI — it is a
local, opt-in confidence check.

In the devcontainer, Claude's credentials arrive via the `${HOME}/.claude.json`
bind mount. Codex CLI keeps its credential under `~/.codex` (bind-mounted as
the `codex-data` volume) — run `codex login` once and it persists across
rebuilds. OpenCode's credential lives in a named volume (`opencode-data`), so
authenticate once per container:

```sh
opencode auth login
```

It then persists across rebuilds. Until you do, the live OpenCode tests skip.

Gemini CLI (opt-in — see below) keeps its OAuth credential under `~/.gemini`,
bind-mounted as the `gemini-data` volume — run `gemini` once in the container
and complete its browser OAuth flow on first prompt; it then persists across
rebuilds the same way.

GitHub Copilot CLI keeps its credential under `~/.copilot` — run `copilot`
once and complete `/login`. A stray `GH_TOKEN` in the environment (common in
devcontainers/CI, exported for other tooling) shadows that stored credential
and makes every call fail authentication even when `copilot` itself is
logged in; `run_copilot`/`require_live_copilot` (`helpers.bash`) already
unset it for every invocation they make, so this is only a concern if you
invoke `copilot` yourself outside the suite to debug.

**Copilot CLI caveat:** its own `preToolUse` event can't inject context (only
`postToolUse` can), so its scoped rules land right after the edit rather than
before it — see the root README's Supported CLI agents section. Intent
skills, by contrast, need no Copilot-specific work at all: `copilot skill
--help` documents that it discovers project skills from `.github/skills/`,
`.agents/skills/`, or `.claude/skills/` natively, and `agent-apropos generate`
already writes the latter for Claude Code/OpenCode — Copilot just picks it
up. Verified by isolating the two possible causes: with the skill file
present but the target module removed, Copilot cited the skill's guidance
verbatim; with the skill file removed but the module left in place, it used
neither. So the "Intent skill ... (Copilot)" pair is a genuine proof, same as
every other agent's.

**Copilot removal-rule caveat:** the "Removal rule" case's Copilot "with"
test is a known, reproducible failure (confirmed across repeated live runs)
— but not a wiring gap. Its session cache
(`.cache/agent-apropos/sessions/*.json`) shows the hook firing and injecting
the rule correctly every time (`"event": "PostToolUse"`,
`"matched_patterns": ["services/**"]`), yet the model still ends its turn
right after the `rm` without acting on the newly-injected context. The same
postToolUse-only mechanism *does* land for a write-triggered rule (that's
what the caveat above already proves) — the difference here seems to be that
a lone shell command reads as "done" to Copilot's single-shot completion in
a way a file edit doesn't, so it wraps up before re-engaging with content
injected after the tool call returns. Left in the matrix, not skipped, so a
future Copilot CLI behavior change shows up here rather than staying hidden.

**Codex CLI caveat:** unlike Gemini/Copilot, its `PreToolUse` event *can*
inject context, so scoped rules land before the write, same as Claude — but its
own file-editing tool, `apply_patch`, can bundle several files' Add/Update
sections into a single call (a real capture of this shape lives at
`spec/fixtures/hook_payloads/codex_*_apply_patch.json`); `Hook::Payload`
parses it and matches/dedups per file (see `agents/codex.cr`). `run_codex`
passes `--dangerously-bypass-hook-trust` because every test stands up a
fresh git repo with a `.codex/hooks.json` Codex has never reviewed before —
without it Codex silently refuses to run the hook rather than prompting, so
agent-apropos would never fire and "with" would look identical to "without".
Intent skills needed their own root, unlike Copilot: Codex does **not**
discover `.claude/skills/` the way Copilot does (confirmed live — the "with"
test failed against a repo carrying only `.claude/skills/`), but it *does*
discover a repo-local `.codex/skills/` (confirmed live the same way, by
placing the identical wrapper there and re-running) — a separate root from
its default global `~/.codex/skills`. `agent-apropos generate` now writes
both.

## Options

- `E2E_GEMINI=1` — include Gemini CLI in the live matrix. Off by default:
  even a healthy round trip has been observed taking 30-60s for a bare
  no-tool-use prompt and well over 180s for a real edit-task prompt, which
  makes default e2e runs slow and unpredictable. `require_live_gemini`/
  `run_gemini` (`helpers.bash`) remain fully working — set this when you
  deliberately want Gemini coverage. **The "Removal rule" case excludes
  Gemini even when opted in** (`register_live_tests`'s exclusion arg,
  `helpers.bash`): Gemini CLI's `run_shell_command` does not fire any hook
  event in the versions tested, confirmed by reading its own bundled
  dispatch logic and by isolating it against its otherwise-working
  `write_file`/`replace` hooks — a genuine CLI limitation, not something
  agent-apropos can route around from the hook side (see `agents/gemini.cr`'s
  section in `docs/design/agent-dialects.md`), so registering a test that
  can never pass would just be noise in an opted-in run.
- `E2E_MODEL=<model>` — pass a specific model to `claude -p --model` /
  `opencode run --model` / `gemini -p --model` / `copilot -p --model`
  (default: each CLI's configured model). Use a small model (e.g.
  `E2E_MODEL=claude-haiku-4-5`) for cheaper runs.
- `bash e2e/run.sh --no-tempdir-cleanup` — keep the per-test temp dirs for
  inspection.
