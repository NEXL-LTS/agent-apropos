# Manual test rig — Layer 2 (two rules, one file)

Five wired, git-initialized copies of `e2e/project/` — one per CLI agent — for
driving a real agent by hand and watching the `api-auth-rule.md` /
`api-throttle-rule.md` pair land together, without going through bats. Not
part of `make e2e` or CI.

## Setup / reset

```sh
bash e2e/manual-test/setup.sh
```

Creates (or recreates from scratch) `/tmp/agent-apropos-manual/{claude,opencode,copilot,codex,gemini}/`,
each already wired (hooks, `.cache/agent-apropos/index.json`, generated
skills) and its own git repo, so you can run a different agent in each
folder at the same time without them stepping on each other's session/lock
state. Re-run it any time you edit `e2e/conventions/` or `e2e/project/` to
pick up the change — it wipes and rebuilds each folder from scratch.

**Deliberately under `/tmp`, not inside this repo.** A copy living at (say)
`e2e/manual-test/claude/` would put `e2e/conventions/` only two directories
above its own cwd — a sibling a CLI agent's own upward exploration (`ls
../..`, `find`, its own auto-included workspace listing) could stumble on
directly, independent of whether agent-apropos's hooks fired at all. That's
exactly the ambient-discovery risk `tests/helpers.bash`'s `BATS_TEST_TMPDIR`
placement (outside the repo) exists to prevent for the live bats suite;
`/tmp/agent-apropos-manual/` keeps that same isolation here.

**Conventions live *inside* each copy, under a random folder name.** Unlike
the live bats suite (which points `conventions_dir` at a real path *outside*
the repo), `setup.sh` copies `e2e/conventions/` into each per-agent copy
under a freshly random, non-descriptive folder name (never
"docs"/"conventions"/anything that reads as "look here") and points
`conventions_dir` at it as a plain relative path. This is a deliberately
different isolation strategy, tried after the outside-the-repo one showed a
real downside live: a citation like `Convention (../../conventions/foo.md):`
told Claude in plain text that the source was outside its own repository,
and — combined with the `AGENTS.md`/`CLAUDE.md` note asking it to trust
exactly such a citation — at least one live run flagged that combination as
a textbook prompt-injection pattern and refused to apply the convention.
Putting the docs inside the repo removes that "outside my repository"
signal; the random folder name is what keeps them from being casually
stumbled on by an agent's own directory listing, same intent, different
mechanism.

**The `conventions_dir` pointer lives at `.cache/agent-apropos.yml`, not a
root-level `agent-apropos.yml`.** `Config` (`src/agent_apropos/config.cr`)
checks this undocumented fallback location only when the root-level file is
absent — real users still configure `conventions_dir` via the documented
root file (see the root `README.md`'s "Configuration" section); this rig
simply never writes one. A root-level `agent-apropos.yml` turned out to be
exactly what a curious agent looks for: observed live, OpenCode's `build`
agent ran `ls` on the repo root, `cat agent-apropos.yml`, then `cat`'d the
random folder's contents directly — the random name didn't stop it, since
the name is only obscure to a human, not to `ls`. `.cache/` already reads as
machine-generated, disposable output, so a config file there draws far less
of that curiosity. Both of these are experiments scoped to this manual rig
only — the live bats suite (`e2e/conventions/`, `e2e/project/`,
`tests/helpers.bash`) still uses a root-level `agent-apropos.yml` pointing
outside the repo, unchanged.

`agent-apropos` must resolve on `PATH` as the bare command (the wiring calls
`agent-apropos hook pre|post`):

```sh
export PATH="$(git rev-parse --show-toplevel)/bin:$PATH"
```

## The prompt

In each agent's folder, ask it to touch `api/handlers.py`:

> Add a function get_status() to api/handlers.py that returns a handler status dict.

A correct, fully-steered result wraps the new `get_status` in **both**
`@rate_limited` and `@require_auth`, with `@rate_limited` listed first
(outermost) — see `api-throttle-rule.md` for why that order, not the more
intuitive "auth first," is correct. `ping()` is left alone; it predates both
rules.

## Running each agent

One-shot, non-interactive (matches what the live bats suite runs) — or just
`cd` into the folder and run the CLI interactively if you'd rather watch it
work turn by turn.

```sh
# Claude Code
cd /tmp/agent-apropos-manual/claude
claude -p "Add a function get_status() to api/handlers.py that returns a handler status dict." \
  --permission-mode auto

# OpenCode
cd /tmp/agent-apropos-manual/opencode
opencode run "Add a function get_status() to api/handlers.py that returns a handler status dict."

# GitHub Copilot CLI (disable repo-hook trust prompt; unset a stray GH_TOKEN if you have one)
cd /tmp/agent-apropos-manual/copilot
env -u GH_TOKEN GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true \
  copilot -p "Add a function get_status() to api/handlers.py that returns a handler status dict." \
  --allow-all-tools

# Codex CLI (fresh repo + unreviewed .codex/hooks.json, so both bypass flags are required)
cd /tmp/agent-apropos-manual/codex
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust \
  "Add a function get_status() to api/handlers.py that returns a handler status dict."

# Gemini CLI (slow — see e2e/README.md's Options section; needs a workspace-trust bypass)
cd /tmp/agent-apropos-manual/gemini
gemini -p "Add a function get_status() to api/handlers.py that returns a handler status dict." \
  --approval-mode auto_edit --skip-trust
```

Then check the result:

```sh
cat api/handlers.py   # from inside whichever agent's folder you ran
```

## Removing the "with" contrast

To see the control (no agent-apropos wired) for a given folder, mirror what
`tests/helpers.bash`'s `new_sample("without")` does: point `conventions_dir`
at a directory that doesn't exist, blank out the hook wiring, and delete the
supporting modules the rules point to —

```sh
cd /tmp/agent-apropos-manual/claude
echo "conventions_dir: /nonexistent" > .cache/agent-apropos.yml
printf '{"hooks":{}}\n' > .claude/settings.json
rm -rf .claude/skills api/auth.py api/throttle.py
```

— then re-run the same prompt and confirm neither `@rate_limited` nor
`@require_auth` appears. Re-run `setup.sh` afterward to restore the "with"
wiring.
