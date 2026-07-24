require "../check"
require "../environment"
require "../filesystem"
require "../hooks/payload"

module AgentApropos
  module Agents
    # One CLI agent `agent-apropos init`/`agent-apropos doctor` know how to wire
    # hooks for (Claude Code, OpenCode, Gemini CLI, GitHub Copilot CLI, ...).
    # `#scaffold` writes or merges this agent's own hook config into the
    # repo; `#checks` (run by `Doctor`) reports whether it is correctly wired.
    # Adding a new agent (Codex, Cursor CLI, ...) is writing one new subclass
    # and registering it in `Agents::ALL` — neither `Init` nor `Doctor` needs
    # a new per-agent branch.
    abstract class Agent
      # The `--tool <name>` value / auto-detect PATH probe name.
      abstract def name : String

      # Write or merge this agent's hook wiring into the repo. Must be
      # idempotent (safe to re-run) the same way `Init.run` as a whole is —
      # implementations use `Init.sync`/`Init.create` so a re-run with
      # unchanged content is a no-op.
      abstract def scaffold(repo_root : Path, fs : Filesystem, options : Init::Options, stdout : IO) : Nil

      # Probe whether this agent is correctly wired, for `agent-apropos
      # doctor`. Every check but Claude's `.claude/settings.json` presence is
      # advisory-only (`:ok`/`:warn`, never `:fail`) — an agent that is not
      # on PATH must never penalise a repo that doesn't use it. Returns an
      # array (not a single `Check`) because Claude reports two: hooks
      # wiring and CLI version capability.
      abstract def checks(repo_root : Path, fs : Filesystem, env : Environment) : Array(Check)

      # Whether this agent's own dialect marks `payload` as having come from
      # a *read* tool rather than an edit/write one. `Hook` calls this only
      # to label a `SessionState::Cause` for debugging (`"agent"` vs the
      # numeric layer) — it never gates whether a rule is matched or
      # delivered, so a wrong answer here costs a debugging label, not
      # correctness.
      abstract def read?(payload : Hook::Payload) : Bool
    end
  end
end
